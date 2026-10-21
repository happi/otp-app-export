/*
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson AB 2020-2026. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * %CopyrightEnd%
 */

#include "beam_asm.hpp"

extern "C"
{
#include "beam_common.h"
}

void BeamGlobalAssembler::emit_dispatch_return() {
    a.mov(ARG3, a64::x30);
    a.str(ZERO, a64::Mem(c_p, offsetof(Process, current)));
    mov_imm(TMP1, 1);
    a.strb(TMP1.w(), a64::Mem(c_p, offsetof(Process, arity)));
    a.b(labels[context_switch_simplified]);
}

void BeamModuleAssembler::emit_dispatch_return(bool set_I) {
#ifdef JIT_HARD_DEBUG
    /* Validate return address and {x,0} */
    emit_validate(ArgVal(ArgVal::Type::Word, 1));
#endif

    if (erts_alcu_enable_code_atags || set_I) {
        /* See emit_i_test_yield. */
        a.str(a64::x30, a64::Mem(c_p, offsetof(Process, i)));
    }

    /* The reduction test is kept in module code because moving it to a shared
     * fragment caused major performance regressions in dialyzer. */
    a.subs(FCALLS, FCALLS, imm(1));
    a.b_mi(resolve_fragment(ga->get_dispatch_return(), disp1MB));

    a.ret(a64::x30);

    mark_unreachable();
}

void BeamModuleAssembler::emit_return() {
    emit_return_do(false);
}

void BeamModuleAssembler::emit_return_do(bool set_I) {
    emit_leave_erlang_frame();
    emit_dispatch_return(set_I);
}

void BeamModuleAssembler::emit_move_deallocate_return() {
    a.ldp(XREG0, a64::x30, a64::Mem(E).post(16));
    emit_dispatch_return(false);
}

/*
 * Scope-restricted export visibility check (EEP 80)
 * Export must be in export_reg.
 * Passes caller module atom directly (known at compile time).
 */
void BeamModuleAssembler::emit_check_scope_visibility(a64::Gp export_reg, Label &allowed) {
    /* Save Export pointer before entering runtime */
    a.str(export_reg, TMP_MEM1q);

    emit_enter_runtime_frame();
    emit_enter_runtime<Update::eReductions | Update::eStack | Update::eHeap>();

    a.mov(ARG1, c_p);
    a.ldr(ARG2, TMP_MEM1q);  /* Load Export pointer */
    /* Pass the caller module atom (known at compile time) as ARG3 */
    mov_imm(ARG3, mod);

    runtime_call<int (*)(Process *, const Export *, Eterm),
                 erts_check_scope_visibility_jit>();

    emit_leave_runtime<Update::eReductions | Update::eStack | Update::eHeap>();
    emit_leave_runtime_frame();

    /* Check return value: 0 = allowed, non-zero = blocked */
    Label blocked = a.new_label();
    a.cmp(ARG1, imm(0));
    a.b_ne(blocked);

    /* Allowed path - restore Export pointer for caller */
    a.ldr(ARG1, TMP_MEM1q);
    a.b(allowed);

    /* Blocked path - error already set in c_p->freason and c_p->fvalue */
    a.bind(blocked);
    a.mov(ARG2, a64::x30);  /* Pass return address for exception */
    mov_imm(ARG4, 0);
    a.b(resolve_fragment(ga->get_raise_exception_shared(), disp128MB));
}

/*
 * Preserve caller app for tail calls through error_handler (EEP 80)
 */
void BeamModuleAssembler::emit_preserve_caller_scope_for_error_handler() {
    Label skip = a.new_label();

    /* Check if c_p->caller_scope is already set (not THE_NON_VALUE) */
    a.ldr(TMP1, a64::Mem(c_p, offsetof(Process, caller_scope)));
    mov_imm(TMP2, THE_NON_VALUE);
    a.cmp(TMP1, TMP2);
    a.b_ne(skip);  /* Already set, skip */

    /* Call erts_preserve_caller_scope_for_error_handler(c_p, c_p->caller_saved_i) */
    emit_enter_runtime_frame();
    emit_enter_runtime<Update::eReductions | Update::eStack | Update::eHeap>();

    a.mov(ARG1, c_p);
    a.ldr(ARG2, a64::Mem(c_p, offsetof(Process, caller_saved_i)));

    runtime_call<void (*)(Process *, ErtsCodePtr),
                 erts_preserve_caller_scope_for_error_handler>();

    emit_leave_runtime<Update::eReductions | Update::eStack | Update::eHeap>();
    emit_leave_runtime_frame();

    a.bind(skip);
}

/*
 * Gate any external dispatch with the scope-visibility check.
 * Assumes ARG1 holds the Export pointer; ARG1 still holds it on the
 * allowed fall-through path. Tail-call sites pass is_tail=true so
 * caller_scope is preserved across the error_handler trampoline.
 */
void BeamModuleAssembler::emit_scope_visibility_gate(bool is_tail) {
    Label gate_pc = a.new_label();
    Label skip_check = a.new_label();
    Label allowed = a.new_label();

    /* Stash a PC inside the current function on c_p->caller_saved_i so
     * call_error_handler can recover the caller's scope if this external
     * call lands in a stub Export and bounces through error_handler.
     * This is required to cover direct calls to never-loaded same-scope
     * restricted functions (ep->scope_restricted reads 0 before the target
     * module loads, so the cbz below would otherwise skip the gate). */
    a.bind(gate_pc);
    a.adr(TMP1, gate_pc);
    a.str(TMP1, a64::Mem(c_p, offsetof(Process, caller_saved_i)));

    a.ldr(TMP1.w(), a64::Mem(ARG1, offsetof(Export, scope_restricted)));
    a.cbz(TMP1, skip_check);

    /* The JIT helper does a fresh lookup using the baked-in caller module
     * atom, so the c_p->caller_scope cache is *not* used as primary input
     * here - no invalidation needed. The cache is only consulted in the
     * error_handler bounce fallback inside the helper. */
    (void)is_tail;
    emit_check_scope_visibility(ARG1, allowed);

    a.bind(allowed);
    a.bind(skip_check);
}

void BeamModuleAssembler::emit_i_call(const ArgLabel &CallTarget) {
    erlang_call(resolve_beam_label(CallTarget, disp128MB));
}

void BeamModuleAssembler::emit_i_call_last(const ArgLabel &CallTarget,
                                           const ArgWord &Deallocate) {
    emit_deallocate(Deallocate);
    emit_i_call_only(CallTarget);
}

void BeamModuleAssembler::emit_move_call_last(const ArgYRegister &Src,
                                              const ArgRegister &Dst,
                                              const ArgLabel &CallTarget,
                                              const ArgWord &Deallocate) {
    auto src_index = Src.get();
    Sint deallocate = Deallocate.get() * sizeof(Eterm);

    if (src_index == 0 && deallocate == 8) {
        auto dst = init_destination(Dst, TMP1);
        const a64::Mem src_ref = a64::Mem(E).post(2 * deallocate);
        a.ldp(dst.reg, a64::x30, src_ref);
        flush_var(dst);
        a.b(resolve_beam_label(CallTarget, disp128MB));
        mark_unreachable();
    } else if (src_index == 0 && Support::is_int_n<9>(deallocate)) {
        auto dst = init_destination(Dst, TMP1);
        const a64::Mem src_ref = a64::Mem(E).post(deallocate);
        a.ldr(dst.reg, src_ref);
        flush_var(dst);
        emit_i_call_only(CallTarget);
    } else if (src_index + 1 == Deallocate.get()) {
        auto dst = init_destination(Dst, TMP1);
        safe_ldp(dst.reg, a64::x30, getArgRef(Src));
        flush_var(dst);
        add(E, E, (Deallocate.get() + 1) * sizeof(Eterm));
        a.b(resolve_beam_label(CallTarget, disp128MB));
        mark_unreachable();
    } else {
        mov_arg(Dst, Src);
        emit_deallocate(Deallocate);
        emit_i_call_only(CallTarget);
    }
}

void BeamModuleAssembler::emit_i_call_only(const ArgLabel &CallTarget) {
    emit_leave_erlang_frame();
    a.b(resolve_beam_label(CallTarget, disp128MB));
    mark_unreachable();
}

/* Handles save_calls for remote calls. When the active code index is
 * ERTS_SAVE_CALLS_CODE_IX, all remote calls will land here.
 *
 * Export entry is in ARG1, return address is in LR (x30). Both of these must
 * be preserved since this runs between caller and callee. */
void BeamGlobalAssembler::emit_dispatch_save_calls_export() {
    a.str(ARG1, TMP_MEM1q);

    emit_enter_runtime_frame();
    emit_enter_runtime();

    a.mov(ARG2, ARG1);
    a.mov(ARG1, c_p);
    runtime_call<void (*)(Process *, const Export *), save_calls>();

    emit_leave_runtime();
    emit_leave_runtime_frame();

    a.ldr(ARG1, TMP_MEM1q);

    /* Keep going with the actual code index. */
    a.mov(TMP1, imm(&the_active_code_index));
    a.ldr(TMP1.w(), a64::Mem(TMP1));

    branch(emit_setup_dispatchable_call(ARG1, TMP1));
}

void BeamModuleAssembler::emit_i_call_ext(const ArgExport &Exp) {
    mov_arg(ARG1, Exp);
    emit_scope_visibility_gate(false);
    a64::Mem target = emit_setup_dispatchable_call(ARG1);
    erlang_call(target);
}

void BeamModuleAssembler::emit_i_call_ext_only(const ArgExport &Exp) {
    mov_arg(ARG1, Exp);
    emit_scope_visibility_gate(true);
    a64::Mem target = emit_setup_dispatchable_call(ARG1);
    emit_leave_erlang_frame();
    branch(target);
    mark_unreachable();
}

void BeamModuleAssembler::emit_i_call_ext_last(const ArgExport &Exp,
                                               const ArgWord &Deallocate) {
    emit_deallocate(Deallocate);
    emit_i_call_ext_only(Exp);
}

void BeamModuleAssembler::emit_move_call_ext_last(const ArgYRegister &Src,
                                                  const ArgRegister &Dst,
                                                  const ArgExport &Exp,
                                                  const ArgWord &Deallocate) {
    auto src_index = Src.get();
    Sint deallocate = Deallocate.get() * sizeof(Eterm);

    if (src_index == 0 && deallocate == 8) {
        auto dst = init_destination(Dst, TMP1);
        const a64::Mem src_ref = a64::Mem(E).post(2 * deallocate);
        mov_arg(ARG1, Exp);
        emit_scope_visibility_gate(true);
        a64::Mem target = emit_setup_dispatchable_call(ARG1);
        a.ldp(dst.reg, a64::x30, src_ref);
        flush_var(dst);
        branch(target);
        mark_unreachable();
    } else if (src_index == 0 && Support::is_int_n<9>(deallocate)) {
        auto dst = init_destination(Dst, TMP1);
        const a64::Mem src_ref = a64::Mem(E).post(deallocate);
        a.ldr(dst.reg, src_ref);
        flush_var(dst);
        emit_i_call_ext_only(Exp);
    } else if (src_index + 1 == Deallocate.get()) {
        auto dst = init_destination(Dst, TMP1);
        mov_arg(ARG1, Exp);
        emit_scope_visibility_gate(true);
        a64::Mem target = emit_setup_dispatchable_call(ARG1);
        safe_ldp(dst.reg, a64::x30, getArgRef(Src));
        flush_var(dst);
        add(E, E, (Deallocate.get() + 1) * sizeof(Eterm));
        branch(target);
        mark_unreachable();
    } else {
        mov_arg(Dst, Src);
        emit_deallocate(Deallocate);
        emit_i_call_ext_only(Exp);
    }
}

static ErtsCodeMFA apply3_mfa = {am_erlang, am_apply, 3};

a64::Mem BeamModuleAssembler::emit_variable_apply(bool includeI) {
    Label dispatch = a.new_label(), entry = a.new_label();

    a.bind(entry);

    /* Stash the apply-entry PC so apply() (and the bounce-second-apply
     * from error_handler) can recover the original caller's scope via
     * erts_find_function_from_pc. */
    a.adr(TMP1, entry);
    a.str(TMP1, a64::Mem(c_p, offsetof(Process, caller_saved_i)));

    emit_enter_runtime<Update::eReductions | Update::eHeapAlloc |
                       Update::eXRegs>(3);

    a.mov(ARG1, c_p);
    load_x_reg_array(ARG2);

    if (includeI) {
        a.adr(ARG3, entry);
    } else {
        mov_imm(ARG3, 0);
    }

    mov_imm(ARG4, 0);

    comment("apply()");
    runtime_call<const Export *(*)(Process *, Eterm *, ErtsCodePtr, Uint),
                 apply>();

    /* Any number of X registers can be live at this point. */
    emit_leave_runtime<Update::eReductions | Update::eHeapAlloc |
                       Update::eXRegs>();

    a.cbnz(ARG1, dispatch);
    emit_raise_exception(entry, &apply3_mfa);

    a.bind(dispatch);
    /* ARG1 holds the resolved Export from apply(). Gate the dispatch. */
    emit_scope_visibility_gate(includeI);
    return emit_setup_dispatchable_call(ARG1);
}

void BeamModuleAssembler::emit_i_apply() {
    a64::Mem target = emit_variable_apply(false);
    erlang_call(target);
}

void BeamModuleAssembler::emit_i_apply_last(const ArgWord &Deallocate) {
    emit_deallocate(Deallocate);
    emit_i_apply_only();
}

void BeamModuleAssembler::emit_i_apply_only() {
    a64::Mem target = emit_variable_apply(true);

    emit_leave_erlang_frame();
    branch(target);
    mark_unreachable();
}

a64::Mem BeamModuleAssembler::emit_fixed_apply(const ArgWord &Arity,
                                               bool includeI) {
    Label dispatch = a.new_label(), entry = a.new_label();

    a.bind(entry);

    /* Stash the apply-entry PC; see emit_variable_apply for rationale. */
    a.adr(TMP1, entry);
    a.str(TMP1, a64::Mem(c_p, offsetof(Process, caller_saved_i)));

    mov_arg(ARG3, Arity);

    emit_enter_runtime<Update::eReductions | Update::eHeapAlloc |
                       Update::eXRegs>(Arity.get() + 2);

    a.mov(ARG1, c_p);
    load_x_reg_array(ARG2);

    if (includeI) {
        a.adr(ARG4, entry);
    } else {
        mov_imm(ARG4, 0);
    }

    mov_imm(ARG5, 0);

    runtime_call<const Export *(*)(Process *, Eterm *, Uint, ErtsCodePtr, Uint),
                 fixed_apply>();

    /* We will need to reload all X registers in case there has been
     * an error. */
    emit_leave_runtime<Update::eReductions | Update::eHeapAlloc |
                       Update::eXRegs>();

    a.cbnz(ARG1, dispatch);
    emit_raise_exception(entry, &apply3_mfa);

    a.bind(dispatch);

    /* ARG1 holds the resolved Export from fixed_apply(). Gate the dispatch. */
    emit_scope_visibility_gate(includeI);

    return emit_setup_dispatchable_call(ARG1);
}

void BeamModuleAssembler::emit_apply(const ArgWord &Arity) {
    a64::Mem target = emit_fixed_apply(Arity, false);
    erlang_call(target);
}

void BeamModuleAssembler::emit_apply_last(const ArgWord &Arity,
                                          const ArgWord &Deallocate) {
    emit_deallocate(Deallocate);

    a64::Mem target = emit_fixed_apply(Arity, true);

    emit_leave_erlang_frame();
    branch(target);
    mark_unreachable();
}
