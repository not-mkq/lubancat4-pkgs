#!/usr/bin/env python3
"""Check the /boot/overlays this package ships against the base .dtb they are applied to.

Why this exists instead of "the overlay patched N lines of the base tree, fine":

  A .dtbo can patch lines, report success, and still not deliver the hardware. Nodes that a
  plugin declares at its own root (backlights, regulators, anything not tied to an existing
  label) stay children of the overlay blob's own "/" unless they are wrapped in
      fragment@N { target-path = "/"; __overlay__ { ... }; };
  and an overlay applier only applies "__overlay__" subtrees. The nodes are then dropped
  silently, while the node that referenced them keeps a phandle pointing at nothing. That is
  how four of our .dtbo files shipped: the panel came through, the backlight and the panel
  power rail did not, and a line-count check called it a pass because the dangling phandle
  itself is one of the lines that changed.

So this checks content, not volume:

  L1a  fdtoverlay applies it at all.
  L1b  the strings the driver matches on are in the merged tree.
  L1c  the nodes landed where the base tree's own __symbols__ say the targeted labels live
       (so "the panel is under the DSI host" is verified, not assumed).
  L1d  every phandle in the watched properties of the whole merged tree resolves to a node
       that exists. This is the check that would have caught the bug above.
  L2   a deliberately broken overlay must still fail, so the checks cannot pass vacuously.

Usage: check-overlays.py <base.dtb> <overlays-dir> [name ...]
Names are given without the "rk3588s-lubancat4-" prefix and without ".dtbo"; with no names,
every rk3588s-lubancat4-*.dtbo in the directory is checked.
"""

import os
import re
import subprocess
import sys

DTB = sys.argv[1] if len(sys.argv) > 1 else ''
OVDIR = sys.argv[2] if len(sys.argv) > 2 else ''
NAMES = sys.argv[3:]

PREFIX = 'rk3588s-lubancat4-'
PATHS = {}   # overlay 名 -> 磁盘上的 .dtbo 路径，在 main() 里解析一次


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    return p.returncode, p.stdout, p.stderr


BASE_DTS = ''   # set once in main(); the base tree decompiled, for the no-op check


def decompile(dtb_path):
    rc, out, err = run(['dtc', '-I', 'dtb', '-O', 'dts', dtb_path])
    if rc:
        sys.exit('dtc cannot read %s: %s' % (dtb_path, err.strip()))
    return out


class Tree:
    """A shallow indentation parse of dtc's dts output.

    Only what the checks need: node paths, their properties, and the phandle each node
    advertises. A real parser would be dtparse.y, which is not worth carrying here, but the
    depth bookkeeping has to be right or whole subtrees quietly vanish -- a first version of
    this file parsed 173 of a kernel dtb's several thousand nodes and reported an empty
    __symbols__, which reads exactly like "the base dtb has no symbols".
    """

    def __init__(self, dts):
        self.props = {}          # path -> {name: value string}
        self.children = {}       # path -> [child paths]
        self.by_phandle = {}     # phandle int -> path
        stack = []               # [(tab depth of the node's own line, path)]
        for raw in dts.splitlines():
            line = raw.rstrip('\n')
            if not line.strip() or line.lstrip().startswith(('/*', '*')):
                continue
            st = line.strip()
            if st in (';', '};'):
                continue
            depth = len(line) - len(line.lstrip('\t'))
            while stack and stack[-1][0] >= depth:
                stack.pop()
            parent = stack[-1][1] if stack else None
            # dtc 会把 label 一起打出来（cpu_l0: cpu@0 {），根节点写成 "/ {" 且没有名字，
            # 这两样都要接住，否则一棵子树就没了——上一版就是这样把 1098 个节点读成 178 个。
            m = re.match(r'(?:([A-Za-z_][A-Za-z0-9_\-]*):\s*)?(/?)([A-Za-z0-9_,.:#\-]*)'
                         r'(@[A-Za-z0-9,.#\-]+)?\s*\{$', st)
            if m and (m.group(3) or m.group(2) == '/'):
                name = m.group(3) + (m.group(4) or '')
                if m.group(2) == '/' or parent is None:
                    path = '/' + name
                elif parent == '/':
                    path = '/' + name
                else:
                    path = parent + '/' + name
                self.props.setdefault(path, {})
                if parent is not None:
                    self.children.setdefault(parent, []).append(path)
                stack.append((depth, path))
                continue
            # 属性有两种写法：name = <value>; 和光一个 name;（空属性就是布尔属性，
            # 像 gpio-controller; / touchscreen-inverted-x; ）。只认前一种的话，
            # 所有布尔属性都看不见，然后会去怪 overlay 少写了东西。
            if parent is not None and re.match(r'[A-Za-z0-9_\-#]+;$', st):
                self.props[parent][st[:-1]] = ''
                continue
            m = re.match(r'([A-Za-z0-9_\-#]+)\s*=\s*(.*);$', st)
            if m and parent is not None:
                self.props[parent][m.group(1)] = m.group(2)
                if m.group(1) in ('phandle', 'linux,phandle'):
                    v = re.findall(r'0x([0-9a-fA-F]+)', m.group(2))
                    if v:
                        self.by_phandle[int(v[0], 16)] = parent

    def symbols(self):
        """label -> path, straight out of the base tree's __symbols__ (it is compiled -@)."""
        return {k: v.strip('"') for k, v in self.props.get('/__symbols__', {}).items()}


# Properties that carry phandles, classified by how the phandles are laid out so the
# dangling check can walk each one without mistaking a gpio/clk argument cell for a
# phandle (a gpio cell list is <&gpio4 1 0>: the &gpio4 is the phandle, 1 and 0 are
# #gpio-cells arguments).
#
#   'single'  one property == one phandle, no argument cells
#   'list'    every cell is a phandle (pinctrl-0 = <&a &b>)
#   'array:<cells-prop>'  phandle followed by N argument cells, N read off the node the
#              phandle points at via <cells-prop> (e.g. 'gpios' -> '#gpio-cells')
#
# Anything not matched here is deliberately NOT treated as a phandle. The pattern is kept
# narrow and named so the exclusion is a decision, not an oversight: plain integer cell
# lists (reg, interrupts, #address-cells, brightness-levels) must never be scanned, or the
# check would report every small integer as a dangling phandle and get ignored.
def phandle_kind(name):
    if name in ('interrupt-parent', 'backlight', 'phy-handle', 'port', 'remote-endpoint',
                'codec', 'cpu'):
        return 'single'
    if re.fullmatch(r'[a-z0-9-]+-supply', name):
        return 'single'
    if re.fullmatch(r'pinctrl-[0-9]+', name):
        return 'list'
    if name in ('gpio', 'gpios') or name.endswith('-gpios') or name.endswith('-gpio'):
        return 'array:#gpio-cells'
    if name in ('pwms',) or name.endswith('-pwms'):
        return 'array:#pwm-cells'
    if name in ('clocks', 'assigned-clocks') or name.endswith('-clocks'):
        return 'array:#clock-cells'
    if name in ('resets', 'assigned-resets'):
        return 'array:#reset-cells'
    if name == 'dmas':
        return 'array:#dma-cells'
    if name == 'phys':
        return 'array:#phy-cells'
    if name == 'iommus':
        return 'array:#iommu-cells'
    if name == 'power-domains':
        return 'array:#power-domain-cells'
    if name == 'interrupts-extended':
        return 'array:#interrupt-cells'
    if name == 'sound-dai':
        return 'array:#sound-dai-cells'
    if name == 'io-channels':
        return 'array:#io-channel-cells'
    return None


def cell_ints(val):
    """All integer cells of a property value, as ints, in order."""
    return [int(c, 16) for c in re.findall(r'0x([0-9a-fA-F]+)', val)]


def dangling(tree):
    """phandle-valued properties that point at a node not present in the tree.

    Walks every property classified by phandle_kind(). For 'array:...' kinds the argument
    cells are skipped by reading the #*-cells of the provider node, so
    gpios = <&gpio4 1 0> checks &gpio4 and not the two arguments.
    """
    bad = []
    for path, props in tree.props.items():
        if path.startswith('/__'):
            continue
        for name, val in props.items():
            kind = phandle_kind(name)
            if kind is None:
                continue
            cells = cell_ints(val)
            if not cells:
                continue
            if kind == 'single':
                ph = cells[0]
                if ph and ph not in tree.by_phandle:
                    bad.append('%s: %s = <%s ...> 指向不存在的节点' % (path, name, hex(ph)))
            elif kind == 'list':
                for ph in cells:
                    if ph and ph not in tree.by_phandle:
                        bad.append('%s: %s = <%s ...> 指向不存在的节点' % (path, name, hex(ph)))
            else:
                # kind == 'array:<cells-prop>'
                nprop = kind.split(':', 1)[1]
                i = 0
                while i < len(cells):
                    ph = cells[i]
                    if ph and ph not in tree.by_phandle:
                        bad.append('%s: %s = <%s ...> 指向不存在的节点' % (path, name, hex(ph)))
                        i += 1
                        continue
                    # read #*-cells off the provider node, default 0 if absent
                    prov = tree.by_phandle.get(ph)
                    nargs = 0
                    if prov is not None:
                        cv = tree.props.get(prov, {}).get(nprop, '0')
                        nargs = cell_ints(cv)[0] if cell_ints(cv) else 0
                    i += 1 + nargs
    return bad


# What each overlay must have produced. Written per overlay on purpose: a generic "the tree
# got bigger" assertion is exactly the check that passed the broken files.
#
# 'pins' carries the actual gpio pin numbers the overlay must place, so the check can catch
# a base-pin-on-a-V1-board class of mistake (the property name is the same, only the pin
# differs). The key is the child node name (panel@0 / gt911@5d) and the value is the expected
# second cell of that node's reset-gpios / irq-gpios: gpio uses #gpio-cells = <2>, so cell 0
# is the phandle, cell 1 is the pin, cell 2 is the flags.
def dsi_expect(host, i2c, panel_rst_pin, gt_rst_pin, gt_irq_pin):
    return dict(
        strings=['embedfire,ebf410173', 'goodix,gt911', 'pwm-backlight',
                 'regulator-fixed', 'mipi_%s_power' % host],
        # (base label, child node that must appear there, prop that must resolve)
        children=[(host, 'panel@0', ['backlight', 'power-supply', 'reset-gpios']),
                  (i2c, 'gt911@5d', ['interrupt-parent', 'reset-gpios'])],
        # (base label, property that must read "okay")
        enabled=[('%s_in' % host, None), ('%s_out' % host, None), ('%s' % host, 'okay'),
                 ('mipidcphy%s' % host[-1], 'okay'), ('vp%s' % {'dsi0': '2', 'dsi1': '3'}[host], None)],
        # child -> {prop: expected pin cell}; catches base-pin-on-V1 and vice versa
        pins={'panel@0': {'reset-gpios': panel_rst_pin},
              'gt911@5d': {'reset-gpios': gt_rst_pin, 'irq-gpios': gt_irq_pin}},
    )


EXPECT = {
    'dsi0-ebf410173': dsi_expect('dsi0', 'i2c5', 15, 16, 21),        # PB7, PC0, PC5
    'dsi0-ebf410173-v1': dsi_expect('dsi0', 'i2c5', 1, 0, 21),       # PA1, PA0, PC5
    'dsi1-ebf410173': dsi_expect('dsi1', 'i2c6', 27, 21, 20),        # PD3, PC5, PC4
    'dsi1-ebf410173-v1': dsi_expect('dsi1', 'i2c6', 27, 2, 1),       # PD3, PA2, PA1
    'xl9535': dict(strings=['nxp,pca9535', 'gpio-keys'],
                   children=[('i2c6', 'gpio-expander@21', ['interrupt-parent', 'gpio-controller'])],
                   enabled=[], pins={}),
    'xl9535-v1': dict(strings=['nxp,pca9535', 'gpio-keys'],
                      children=[('i2c6', 'gpio-expander@21', ['interrupt-parent', 'gpio-controller'])],
                      enabled=[], pins={}),
    'hdmi0-sound': dict(strings=['simple-audio-card'], children=[], enabled=[], pins={}),
}


def check(name, base, base_syms, workdir):
    ov = PATHS[name]
    merged = os.path.join(workdir, name + '.merged.dtb')
    rc, _, err = run(['fdtoverlay', '-i', base, '-o', merged, ov])
    if rc:
        return ['%s: fdtoverlay 打不上: %s' % (name, err.strip().splitlines()[-1:])]
    dts = decompile(merged)
    tree = Tree(dts)
    probs = []
    want = EXPECT.get(name, {})
    # "applies but changes nothing" is the other failure mode: an overlay whose targets exist
    # but whose content is a no-op. Kept from the old check because the string expectations
    # above could be satisfied by content the base tree already had.
    if len([1 for a, b in zip(BASE_DTS.splitlines(), dts.splitlines()) if a != b]) == 0 and        BASE_DTS.count('\n') == dts.count('\n'):
        probs.append('%s: 打上去之后树没有任何变化' % name)
    for s in want.get('strings', []):
        if s not in dts:
            probs.append('%s: 合并后的树里找不到 "%s"（驱动匹配不上就不会 probe）' % (name, s))

    for label, child, props in want.get('children', []):
        path = base_syms.get(label)
        if path is None:
            probs.append('%s: 基 dtb 的 __symbols__ 里没有 label %s，overlay 无处可打' % (name, label))
            continue
        hits = [c for c in tree.children.get(path, []) if c.split('/')[-1] == child]
        if not hits:
            probs.append('%s: %s 下面没有 %s' % (name, path, child))
            continue
        for p in props:
            if p not in tree.props[hits[0]]:
                probs.append('%s: %s 缺属性 %s' % (name, hits[0], p))
        # F03: assert the gpio pin numbers, not just "the property exists". gpio uses
        # #gpio-cells = <2>, so value cells are <phandle pin flags>; cell index 1 is the pin.
        for prop, want_pin in want.get('pins', {}).get(child, {}).items():
            val = tree.props[hits[0]].get(prop, '')
            cells = cell_ints(val)
            if not cells:
                probs.append('%s: %s 缺属性 %s（无法核对 pin）' % (name, hits[0], prop))
                continue
            got_pin = cells[1] if len(cells) > 1 else None
            if got_pin != want_pin:
                probs.append('%s: %s 的 %s pin 期望 %d，实际 %s' %
                             (name, hits[0], prop, want_pin, got_pin))

        # Goodix uses logical 0/1 as physical reset levels; panel reset is active-low.
        for prop in want.get('pins', {}).get(child, {}):
            cells = cell_ints(tree.props[hits[0]].get(prop, ''))
            flags = 1 if child == 'panel@0' else 0
            if len(cells) != 3 or cells[2] != flags:
                probs.append('%s: %s %s GPIO flags expected %d, got %s' %
                             (name, hits[0], prop, flags, cells))

    for label, want_status in want.get('enabled', []):
        path = base_syms.get(label)
        if path is None:
            probs.append('%s: 基 dtb 没有 label %s' % (name, label))
            continue
        st = tree.props.get(path, {}).get('status')
        if want_status == 'okay' and st not in (None, '"okay"'):
            probs.append('%s: %s 的 status 还是 %s' % (name, path, st))

    # 整棵树范围的悬空 phandle：这一条才是那次事故的探测器
    probs += ['%s: %s' % (name, d) for d in dangling(tree)]
    return probs


def negative_control(base, base_syms, workdir):
    """The content checks must catch a deliberately broken overlay, or they pass vacuously.

    Two independent failures are exercised, matching the checks they exist to validate:

      1. a label the base tree does not have -> fdtoverlay itself must refuse (guards L1a);
      2. a phandle that dangles after a clean apply -> dangling() must report it (guards L1d,
         and specifically F01: the older check never looked at gpio/gpios/irq-gpios, so a
         dangling gpio phandle slipped through). The dangling phandle is produced the way the
         original shipping bug was: a node declared at the plugin root (not inside any
         fragment) is not applied, but another node still references its phandle.
    """
    # 1. unknown label
    src = os.path.join(workdir, 'bad-label.dtso')
    with open(src, 'w') as f:
        f.write('/dts-v1/;\n/plugin/;\n&no_such_label_here { status = "okay"; };\n')
    rc, _, err = run(['dtc', '-@', '-I', 'dts', '-O', 'dtb', '-o',
                      os.path.join(workdir, 'bad-label.dtbo'), src])
    if rc == 0:
        rc, _, err = run(['fdtoverlay', '-i', base, '-o', os.path.join(workdir, 'bad-label.dtb'),
                          os.path.join(workdir, 'bad-label.dtbo')])
        if rc == 0:
            return False  # an unknown label applied: L1a is not guarding anything

    # 2. dangling gpio phandle (F01): compile + apply must succeed (so the failure, if any,
    # comes from dangling()), then dangling() must find the dead phandle.
    src = os.path.join(workdir, 'bad-dangle.dtso')
    with open(src, 'w') as f:
        f.write('/dts-v1/;\n/plugin/;\n'
                '/ {\n'
                '\torphan { phandle = <0xdeadbeef>; };\n'
                '\tfragment@0 { target-path = "/"; __overlay__ {\n'
                '\t\tref { compatible = "test"; gpio = <0xdeadbeef 0>; };\n'
                '\t}; };\n'
                '};\n')
    rc, _, err = run(['dtc', '-@', '-I', 'dts', '-O', 'dtb', '-o',
                      os.path.join(workdir, 'bad-dangle.dtbo'), src])
    if rc:
        return False  # did not even compile: nothing about dangling() was tested
    rc, _, err = run(['fdtoverlay', '-i', base, '-o', os.path.join(workdir, 'bad-dangle.dtb'),
                      os.path.join(workdir, 'bad-dangle.dtbo')])
    if rc:
        return False  # did not apply: dangling() was not the thing under test
    dts = decompile(os.path.join(workdir, 'bad-dangle.dtb'))
    tree = Tree(dts)
    if not dangling(tree):
        return False  # a dangling gpio phandle was not reported (F01 regression)
    return True


def main():
    if not DTB or not OVDIR or not os.path.exists(DTB):
        sys.exit('用法: %s <base.dtb> <overlays-dir> [name ...]' % sys.argv[0])
    global BASE_DTS
    BASE_DTS = decompile(DTB)
    base_syms = Tree(BASE_DTS).symbols()
    if not base_syms:
        sys.exit('基 dtb 没有 /__symbols__：它不是用 -@ 编的，overlay 根本没法打上去')
    # 两种名字都要认：内核构建树里是我们注册的 rk3588s-lubancat4-<名>.dtbo，而包里
    # package() 把板子前缀去掉了，装出来是 /boot/overlays/<名>.dtbo。只认前一种的话，
    # 对着解包出来的目录会一个都不认识 —— 然后打印"0 个全部通过"，这正是最坏的那种假绿。
    found = sorted(f for f in os.listdir(OVDIR) if f.endswith('.dtbo')
                   and (f.startswith(PREFIX) or f[:-len('.dtbo')] in EXPECT))
    names = NAMES or [f[:-len('.dtbo')].removeprefix(PREFIX) for f in found]
    if not names:
        sys.exit('%s 里一个认识的 .dtbo 都没有：检查等于没跑' % OVDIR)
    # 名字和文件名不是一回事（包里的 .dtbo 去掉了板子前缀），所以把找到的路径带上，
    # 别让下一步再去拼一次前缀拼出一个不存在的文件。
    for n in names:
        for cand in (PREFIX + n + '.dtbo', n + '.dtbo'):
            if os.path.exists(os.path.join(OVDIR, cand)):
                PATHS[n] = os.path.join(OVDIR, cand)
                break
        else:
            sys.exit('%s: 名单里有 %s，目录里找不到对应文件' % (OVDIR, n))
    work = os.environ.get('TMPDIR', '/tmp')
    allprobs = []
    for n in names:
        probs = check(n, DTB, base_syms, work)
        print('  %-24s %s' % (n, 'ok' if not probs else ''))
        for p in probs:
            print('      %s' % p)
        allprobs += probs
    if not negative_control(DTB, base_syms, work):
        print('  负面对照没拦住：一个引用不存在 label 的 overlay 居然能打上，这些检查不算数')
        allprobs.append('negative control')
    if allprobs:
        sys.exit(1)
    print('  %d 个 overlay 全部通过（内容检查 + 悬空 phandle 检查 + 负面对照）' % len(names))


main()
