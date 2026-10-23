#!/usr/bin/env python3
"""Summarise lintbench.erl results.

  lintsum.py RESULTS.jsonl [--lcnt LCNT.jsonl] [--compare OTHER.jsonl]

Per (work, K): median over repetitions of pass-1 wall time with new atoms
("cold"), pass-1 wall time with the atoms pre-created serially
("control"), and pass 2 (atoms present) for both. The atom-creation cost
under concurrency is cold - control.
"""
import json, sys, statistics as st, collections, argparse

def load(p):
    out = []
    for l in open(p):
        l = l.strip()
        if l.startswith('{'):
            try: out.append(json.loads(l))
            except json.JSONDecodeError: pass
    return out

def med(xs): return st.median(xs) if xs else float('nan')

def table(rows, label):
    g = collections.defaultdict(list)
    for r in rows:
        g[(r['work'], r['k'], r.get('pre', 'none'), r['pass'])].append(r)
    works = sorted({k[0] for k in g}); ks = sorted({k[1] for k in g})
    print(f"\n### {label}")
    print(f"{'work':5s} {'K':>3s} {'n':>2s} {'cold s':>7s} {'ctrl s':>7s} {'cold-ctrl':>9s} {'%':>6s} {'cold p2':>7s} {'ctrl p2':>7s} "
          f"{'new atoms':>9s} {'cold cpu s':>10s} {'ctrl cpu s':>10s} {'files/s cold':>12s} {'speedup cold':>12s} {'speedup ctrl':>12s}")
    base = {}
    for w in works:
        for k in ks:
            c = g.get((w, k, 'none', 1), []); t = g.get((w, k, 'atoms', 1), [])
            c2 = g.get((w, k, 'none', 2), []); t2 = g.get((w, k, 'atoms', 2), [])
            if not c: continue
            cw = med([r['wall_us'] for r in c]) / 1e6; tw = med([r['wall_us'] for r in t]) / 1e6 if t else float('nan')
            if k == 1: base[w] = (cw, tw)
            b = base.get(w, (float('nan'), float('nan')))
            print(f"{w:5s} {k:3d} {len(c):2d} {cw:7.3f} {tw:7.3f} {cw-tw:9.3f} {100*(cw-tw)/cw:6.1f} "
                  f"{med([r['wall_us'] for r in c2])/1e6:7.3f} {med([r['wall_us'] for r in t2])/1e6 if t2 else float('nan'):7.3f} "
                  f"{med([r['atoms_added'] for r in c]):9.0f} {med([r['cpu_us'] for r in c])/1e6:10.2f} {med([r['cpu_us'] for r in t])/1e6 if t else float('nan'):10.2f} "
                  f"{med([r['files_per_s'] for r in c]):12.1f} {b[0]/cw:12.2f} {b[1]/tw if t else float('nan'):12.2f}")
    # spread
    print("   per-run pass-1 wall (s), cold | control:")
    for w in works:
        for k in ks:
            c = g.get((w, k, 'none', 1), []); t = g.get((w, k, 'atoms', 1), [])
            if c: print(f"   {w:5s} K={k:<3d} " + ' '.join(f"{r['wall_us']/1e6:.3f}" for r in c) + "  |  " + ' '.join(f"{r['wall_us']/1e6:.3f}" for r in t))

def lcnt(rows):
    print("\n### atom_tab lock statistics (lock-counting emulator; pass 1 = new atoms, pass 2 = existing)")
    print(f"{'work':5s} {'K':>3s} {'pre':5s} {'pass':>4s} {'wall s':>7s} {'new':>7s} {'rd tries':>9s} {'rd colls':>8s} {'rd wait ms':>10s} {'wr tries':>8s} {'wr colls':>8s} {'wr wait ms':>10s}")
    for r in sorted(rows, key=lambda r: (r['work'], r['k'], r.get('pre', ''), r['pass'])):
        s = {x['site']: x for x in r.get('atom_tab_sites', [])}
        rd = s.get('beam/atom.c:290', s.get('beam/atom.c:317', {})); wr = {}
        for site, x in s.items():
            if site.startswith('beam/atom.c:') and x is not rd and x['tries'] > 0 and 'wait_us' in x:
                pass
        # the write site is the one with the most tries other than lookups at 290/427/361
        writes = [x for site, x in s.items() if site not in ('beam/atom.c:290', 'beam/atom.c:427', 'beam/atom.c:361', 'undefined:0')]
        wr = max(writes, key=lambda x: x['tries']) if writes else {}
        reads = [x for site, x in s.items() if x is not wr]
        print(f"{r['work']:5s} {r['k']:3d} {r.get('pre','none')[:5]:5s} {r['pass']:4d} {r['wall_us']/1e6:7.3f} {r['atoms_added']:7d} "
              f"{sum(x['tries'] for x in reads):9d} {sum(x['colls'] for x in reads):8d} {sum(x['wait_us'] for x in reads)/1000:10.1f} "
              f"{wr.get('tries',0):8d} {wr.get('colls',0):8d} {wr.get('wait_us',0)/1000:10.1f}")

if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('results'); ap.add_argument('--lcnt'); ap.add_argument('--label', default='results')
    a = ap.parse_args()
    table(load(a.results), a.label)
    if a.lcnt: lcnt(load(a.lcnt))
