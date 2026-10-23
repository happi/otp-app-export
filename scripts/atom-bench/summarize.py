#!/usr/bin/env python3
"""Summarise bench.erl JSONL results.

  summarize.py RESULTS.jsonl [--compare OTHER.jsonl] [--mode warm|split|passes|par|fresh|tprof|all]
"""
import json, sys, statistics as st, collections, argparse

def load(path):
    rows = []
    for line in open(path):
        line = line.strip()
        if line.startswith('{'):
            try: rows.append(json.loads(line))
            except json.JSONDecodeError: pass
    return rows

def med(xs): return st.median(xs) if xs else float('nan')
def by(rows, mode): return [r for r in rows if r.get('mode') == mode]
def group(rows, key='name'):
    g = collections.OrderedDict()
    for r in rows: g.setdefault(r[key], []).append(r)
    return g

CAT_ORDER = {'ordinary': 0, 'large_handwritten': 1, 'generated': 2, 'set': 3}
def sorted_names(groups):
    return sorted(groups, key=lambda n: (CAT_ORDER.get(groups[n][0].get('category', ''), 9), n))

def warm(rows, other=None):
    g = group([r for r in by(rows, 'warm') if r['iter'] > 0])
    first = {r['name']: r for r in by(rows, 'warm') if r['iter'] == 0}
    og = group([r for r in by(other, 'warm') if r['iter'] > 0]) if other else {}
    hdr = f"{'module':28s} {'cat':6s} {'n':>2s} {'wall ms':>8s} {'min ms':>7s} {'cv%':>4s} {'sched ms':>8s} {'gc%':>4s} {'alloc Mw':>8s} {'peak Mw':>7s} {'GCs':>5s} {'atoms+':>6s} {'HWM MB':>6s}"
    if other: hdr += f" {'other ms':>8s} {'ratio':>6s}"
    print(hdr)
    tot = collections.defaultdict(float)
    for n in sorted_names(g):
        rs = g[n]; w = [r['wall_us'] / 1000 for r in rs]
        sched = med([r['sched_active_us'] for r in rs]) / 1000
        gcp = 100 * med([r['msacc_gc_us'] for r in rs]) / max(1, med([r['sched_active_us'] for r in rs]))
        cv = 100 * st.pstdev(w) / med(w) if len(w) > 1 else 0
        line = (f"{n:28s} {rs[0].get('category','')[:6]:6s} {len(rs):2d} {med(w):8.1f} {min(w):7.1f} {cv:4.1f} {sched:8.1f} {gcp:4.1f} "
                f"{med([r['alloc_words_est'] for r in rs])/1e6:8.2f} {med([r['peak_heap_words'] for r in rs])/1e6:7.2f} "
                f"{med([r['gc_minor']+r['gc_major'] for r in rs]):5.0f} {first.get(n,{}).get('atoms_added',0):6d} {med([r['hwm_kb'] for r in rs])/1024:6.0f}")
        if other and n in og:
            ow = [r['wall_us'] / 1000 for r in og[n]]
            line += f" {med(ow):8.1f} {med(ow)/med(w):6.3f}"
        print(line)
        tot['wall'] += med(w); tot['gc'] += med([r['msacc_gc_us'] for r in rs]) / 1000; tot['sched'] += sched
    print(f"{'TOTAL (sum of medians)':28s} {'':6s} {'':2s} {tot['wall']:8.1f} {'':7s} {'':4s} {tot['sched']:8.1f} {100*tot['gc']/max(1,tot['sched']):4.1f}")

def split(rows):
    g = group(by(rows, 'split'))
    wg = group([r for r in by(rows, 'warm') if r['iter'] > 0])
    stages = ['read_file', 'to_list', 'scan_string', 'scan_string_text', 'scan_tokens_chunked', 'epp_scan_file', 'epp_parse_file', 'parse_forms']
    print(f"{'module':28s} {'KB':>5s} {'tokens':>7s} " + ' '.join(f"{s[:12]:>12s}" for s in stages) + f" {'compile ms':>10s} {'epp%':>5s}")
    for n in sorted_names(g):
        r = g[n][-1]; sm = {s['stage']: s for s in r['stages']}
        comp = med([x['wall_us'] for x in wg.get(n, [])]) / 1000 if n in wg else float('nan')
        epp = sm['epp_parse_file']['median_us'] / 1000
        print(f"{n:28s} {r['bytes']/1024:5.0f} {r['tokens']:7d} " + ' '.join(f"{sm[s]['median_us']/1000:12.2f}" for s in stages) + f" {comp:10.1f} {100*epp/comp if comp else 0:5.1f}")
    print("\nallocation (Mwords) per stage:")
    print(f"{'module':28s} " + ' '.join(f"{s[:12]:>12s}" for s in stages))
    for n in sorted_names(g):
        r = g[n][-1]; sm = {s['stage']: s for s in r['stages']}
        print(f"{n:28s} " + ' '.join(f"{sm[s]['alloc_words_est']/1e6:12.3f}" for s in stages))

def passes(rows, top=12):
    g = group(by(rows, 'passes'))
    agg = collections.defaultdict(lambda: collections.defaultdict(float))
    for n in sorted_names(g):
        r = g[n][-1]; total = r['total_median_us']
        ps = sorted(r['passes'], key=lambda p: -p['median_us'])
        print(f"\n{n} ({r['category']}): total {total/1000:.1f} ms (with flat_size overhead)")
        for p in ps[:top]:
            print(f"   {p['pass']:28s} {p['median_us']/1000:8.1f} ms {100*p['median_us']/total:5.1f}%")
        pm = next((p for p in r['passes'] if p['pass'] == 'parse_module'), None)
        if pm: print(f"   -> parse_module share {100*pm['median_us']/total:.1f}%")
        subs = [s for s in r['sub_passes'] if s['pass'] == 'beam_ssa_opt'][:6]
        if subs: print("   beam_ssa_opt sub-passes: " + ', '.join(f"{s['sub']} {s['median_us']/1000:.1f}" for s in subs))
        for p in r['passes']: agg[r['category']][p['pass']] += p['median_us']
    print("\nper-category pass shares (sum over modules):")
    for cat, d in agg.items():
        total = sum(d.values())
        print(f"  {cat}: " + ', '.join(f"{k} {100*v/total:.1f}%" for k, v in sorted(d.items(), key=lambda kv: -kv[1])[:10]))

def par(rows):
    g = group(by(rows, 'par'))
    for n in sorted(g):
        print(f"\nset: {n}")
        print(f"{'K':>2s} {'compiles':>8s} {'wall s':>7s} {'comp/s':>7s} {'speedup':>7s} {'eff%':>5s} {'cpu s':>6s} {'sched s':>7s} {'gc%':>4s} {'atoms+':>6s} {'HWM MB':>6s}")
        base = None
        for r in sorted(g[n], key=lambda r: r['k']):
            cps = r['compiles_per_s']
            if r['k'] == 1: base = cps
            sp = cps / base if base else float('nan')
            print(f"{r['k']:2d} {r['compiles']:8d} {r['wall_us']/1e6:7.2f} {cps:7.2f} {sp:7.2f} {100*sp/r['k']:5.1f} {r['cpu_us']/1e6:6.2f} {r['sched_active_us']/1e6:7.2f} "
                  f"{100*r['msacc_gc_us']/max(1,r['sched_active_us']):4.1f} {r['atoms_added']:6d} {r['hwm_kb']/1024:6.0f}")

def fresh(rows):
    g = group(by(rows, 'fresh'))
    print(f"{'module':28s} {'n':>2s} {'load ms':>8s} {'compile ms':>10s} {'HWM MB':>6s}")
    for n in sorted_names(g):
        rs = g[n]
        print(f"{n:28s} {len(rs):2d} {med([r['load_us'] for r in rs])/1000:8.1f} {med([r['compile_us'] for r in rs])/1000:10.1f} {med([r['hwm_kb'] for r in rs])/1024:6.0f}")

def tprof(rows, top=15):
    for r in by(rows, 'tprof'):
        print(f"\n{r['name']} {r['type']} total={r['total']}")
        for m in r['by_module'][:top]: print(f"   {m['module']:28s} {m['pct']:5.1f}%")
        print("   top functions:")
        for f in r['top_functions'][:top]: print(f"   {f['mfa']:50s} {f['pct']:5.1f}% calls={f['calls']}")

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('results'); ap.add_argument('--compare'); ap.add_argument('--mode', default='all')
    a = ap.parse_args()
    rows = load(a.results); other = load(a.compare) if a.compare else None
    for m in (['warm', 'split', 'passes', 'par', 'fresh', 'tprof'] if a.mode == 'all' else [a.mode]):
        if by(rows, m):
            print(f"\n===== {m} =====")
            {'warm': lambda: warm(rows, other), 'split': lambda: split(rows), 'passes': lambda: passes(rows),
             'par': lambda: par(rows), 'fresh': lambda: fresh(rows), 'tprof': lambda: tprof(rows)}[m]()
