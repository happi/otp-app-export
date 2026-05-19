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
#ifdef NATIVE_ERLANG_STACK
    /* ARG3 should contain the place to jump to. */
    a.pop(ARG3);
#else
    /* ARG3 already contains the place to jump to. */
#endif

    a.mov(x86::qword_ptr(c_p, offsetof(Process, current)), imm(0));
    a.mov(x86::byte_ptr(c_p, offsetof(Process, arity)), imm(1));
    a.jmp(labels[context_switch_simplified]);
}

void BeamModuleAssembler::emit_return() {
    emit_return_do(false);
}

void BeamModuleAssembler::emit_return_do(bool set_I) {
#ifdef JIT_HARD_DEBUG
    /* Validate return address and {x,0} */
    emit_validate(ArgWord(1));
#endif

    emit_leave_frame();

#if !defined(NATIVE_ERLANG_STACK)
    a.mov(ARG3, getCPRef());
    a.mov(getCPRef(), imm(NIL));
#endif

    if (erts_alcu_enable_code_atags || set_I) {
        /* See emit_i_test_yield. */
#if defined(NATIVE_ERLANG_STACK)
        a.mov(ARG3, x86::qword_ptr(E));
#endif
        a.mov(x86::qword_ptr(c_p, offsetof(Process, i)), ARG3);
    }

    /* The reduction test is kept in module code because moving it to a shared
     * fragment caused major performance regressions in dialyzer. */
    a.dec(FCALLS);
    a.jl(resolve_fragment(ga->get_dispatch_return()));

#ifdef NATIVE_ERLANG_STACK
    a.ret();
#else
    a.jmp(ARG3);
#endif
}

void BeamModuleAssembler::emit_i_call(const ArgLabel &CallDest) {
    erlang_call(resolve_beam_label(CallDest), RET);
}

void BeamModuleAssembler::emit_i_call_last(const ArgLabel &CallDest,
                                           const ArgWord &Deallocate) {
    emit_deallocate(Deallocate);
    emit_i_call_only(CallDest);
}

void BeamModuleAssembler::emit_i_call_only(const ArgLabel &CallDest) {
    emit_leave_frame();

    a.jmp(resolve_beam_label(CallDest));
}

/* Handles save_calls for export entries. Export entry is in RET.
 *
 * When the active code index is ERTS_SAVE_CALLS_CODE_IX, all remote calls will
 * land here. */
void BeamGlobalAssembler::emit_dispatch_save_calls_export() {
    a.mov(TMP_MEM1q, RET);

    emit_enter_runtime();

    a.mov(ARG1, c_p);
    a.mov(ARG2, RET);
    runtime_call<void (*)(Process *, const Export *), save_calls>();

    emit_leave_runtime();

    a.mov(RET, TMP_MEM1q);

    /* Keep going with the actual code index. */
    a.mov(ARG1, imm(&the_active_code_index));
    a.mov(ARG1d, x86::dword_ptr(ARG1));

    a.jmp(emit_setup_dispatchable_call(RET, ARG1));
}

void BeamModuleAssembler::emit_save_app_visibility_caller_pc(Label caller_pc) {
    a.lea(ARG1, x86::qword_ptr(caller_pc));
    a.mov(x86::qword_ptr(c_p, offsetof(Process, caller_saved_i)), ARG1);
}

void BeamModuleAssembler::emit_check_app_visibility(const x86::Gp &exp,
                                                    Label caller_pc,
                                                    bool reset_caller_app) {
    a.lea(ARG3, x86::qword_ptr(caller_pc));
    emit_check_app_visibility(exp, ARG3, reset_caller_app);
}

void BeamModuleAssembler::emit_check_app_visibility(const x86::Gp &exp,
                                                    const x86::Gp &caller_pc,
                                                    bool reset_caller_app) {
    Label allowed = a.new_label(), visibility_error = a.new_label();

    a.cmp(x86::dword_ptr(exp, offsetof(Export, app_restricted)), imm(0));
    a.je(allowed);

    a.mov(TMP_MEM1q, exp);
    a.mov(TMP_MEM2q, caller_pc);

    if (reset_caller_app) {
        a.mov(x86::qword_ptr(c_p, offsetof(Process, caller_app)),
              imm(THE_NON_VALUE));
    }

    emit_enter_runtime();

    a.mov(ARG1, c_p);
    a.mov(ARG2, TMP_MEM1q);
    a.mov(ARG3, TMP_MEM2q);
    runtime_call<int (*)(Process *, const Export *, ErtsCodePtr),
                 erts_check_app_visibility>();

    emit_leave_runtime();

    a.test(RETd, RETd);
    a.jne(visibility_error);

    a.mov(exp, TMP_MEM1q);
    a.jmp(allowed);

    a.bind(visibility_error);
    a.mov(exp, TMP_MEM1q);
    a.mov(ARG2, TMP_MEM2q);
    a.and_(ARG2, imm(~_CPMASK));
    emit_raise_exception(ARG2, nullptr);

    a.bind(allowed);
}

void BeamModuleAssembler::emit_check_external_fun_app_visibility(
        const x86::Gp &exp,
        const x86::Gp &fun_thing,
        Label caller_pc,
        bool save_caller_pc) {
    Label local_fun = a.new_label();

    a.mov(ARG2, emit_boxed_val(fun_thing, offsetof(ErlFunThing, thing_word)));
    a.shr(ARG2, imm(FUN_HEADER_KIND_OFFS));
    a.je(local_fun);

    if (save_caller_pc) {
        emit_save_app_visibility_caller_pc(caller_pc);
    }

    emit_check_app_visibility(exp, caller_pc, true);

    a.bind(local_fun);
}

void BeamModuleAssembler::emit_i_call_ext(const ArgExport &Exp) {
    mov_arg(RET, Exp);
    emit_check_app_visibility(RET, current_label, true);
    x86::Mem destination = emit_setup_dispatchable_call(RET);
    erlang_call(destination, ARG1);
}

void BeamModuleAssembler::emit_i_call_ext_only(const ArgExport &Exp) {
    mov_arg(RET, Exp);
    emit_save_app_visibility_caller_pc(current_label);
    emit_check_app_visibility(RET, current_label, true);
    x86::Mem destination = emit_setup_dispatchable_call(RET);

    emit_leave_frame();
    a.jmp(destination);
}

void BeamModuleAssembler::emit_i_call_ext_last(const ArgExport &Exp,
                                               const ArgWord &Deallocate) {
    emit_deallocate(Deallocate);

    mov_arg(RET, Exp);
    emit_save_app_visibility_caller_pc(current_label);
    emit_check_app_visibility(RET, current_label, true);
    x86::Mem destination = emit_setup_dispatchable_call(RET);

    emit_leave_frame();
    a.jmp(destination);
}

static ErtsCodeMFA apply3_mfa = {am_erlang, am_apply, 3};

x86::Mem BeamModuleAssembler::emit_variable_apply(bool includeI) {
    Label dispatch = a.new_label(), entry = a.new_label();

    align_erlang_cp();
    a.bind(entry);

    if (includeI) {
        emit_save_app_visibility_caller_pc(entry);
    }

    emit_enter_runtime<Update::eReductions | Update::eHeapAlloc>();

    a.mov(ARG1, c_p);
    load_x_reg_array(ARG2);

    if (includeI) {
        a.lea(ARG3, x86::qword_ptr(entry));
    } else {
        mov_imm(ARG3, 0);
    }

    mov_imm(ARG4, 0);

    runtime_call<const Export *(*)(Process *, Eterm *, ErtsCodePtr, Uint),
                 apply>();

    emit_leave_runtime<Update::eReductions | Update::eHeapAlloc>();

    a.test(RET, RET);
    a.short_().jne(dispatch);
    emit_raise_exception(entry, &apply3_mfa);
    a.bind(dispatch);

    emit_check_app_visibility(RET, entry, false);

    return emit_setup_dispatchable_call(RET);
}

void BeamModuleAssembler::emit_i_apply() {
    x86::Mem dest = emit_variable_apply(false);
    erlang_call(dest, ARG1);
}

void BeamModuleAssembler::emit_i_apply_last(const ArgWord &Deallocate) {
    emit_deallocate(Deallocate);
    emit_i_apply_only();
}

void BeamModuleAssembler::emit_i_apply_only() {
    x86::Mem dest = emit_variable_apply(true);

    emit_leave_frame();
    a.jmp(dest);
}

x86::Mem BeamModuleAssembler::emit_fixed_apply(const ArgWord &Arity,
                                               bool includeI) {
    Label dispatch = a.new_label(), entry = a.new_label();

    align_erlang_cp();
    a.bind(entry);

    if (includeI) {
        emit_save_app_visibility_caller_pc(entry);
    }

    mov_arg(ARG3, Arity);

    emit_enter_runtime<Update::eReductions | Update::eHeapAlloc>();

    a.mov(ARG1, c_p);
    load_x_reg_array(ARG2);

    if (includeI) {
        a.lea(ARG4, x86::qword_ptr(entry));
    } else {
        mov_imm(ARG4, 0);
    }

    mov_imm(ARG5, 0);

    runtime_call<const Export *(*)(Process *, Eterm *, Uint, ErtsCodePtr, Uint),
                 fixed_apply>();
    emit_leave_runtime<Update::eReductions | Update::eHeapAlloc>();

    a.test(RET, RET);
    a.short_().jne(dispatch);

    emit_raise_exception(entry, &apply3_mfa);
    a.bind(dispatch);

    emit_check_app_visibility(RET, entry, false);

    return emit_setup_dispatchable_call(RET);
}

void BeamModuleAssembler::emit_apply(const ArgWord &Arity) {
    x86::Mem dest = emit_fixed_apply(Arity, false);
    erlang_call(dest, ARG1);
}

void BeamModuleAssembler::emit_apply_last(const ArgWord &Arity,
                                          const ArgWord &Deallocate) {
    emit_deallocate(Deallocate);

    x86::Mem dest = emit_fixed_apply(Arity, true);

    emit_leave_frame();
    a.jmp(dest);
}
