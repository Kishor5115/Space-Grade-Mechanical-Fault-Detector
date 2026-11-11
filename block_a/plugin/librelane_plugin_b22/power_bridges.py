# Bridges the Metal2 VDD/VSS terminals of the organizers' Block A DEF to the PDN.
#
# West-edge terminals: Metal2/Metal3 extension, then a Metal4 riser to the nearest
# same-net Metal5 stripe. North-edge terminals: Metal2/Metal3 extension, then a
# Metal3 bar to the nearest same-net Metal4 stripe. The stripes must reach the die
# edge (PDN_EXTEND_TO: boundary).
import odb
from reader import click_odb, click

EXT = 14.0  # um, extension of each terminal into the block
RISER = 10.0  # um, width of the Metal4 riser and the Metal3 bar
CUT, CUT_SPACING, ENCLOSURE = 0.26, 0.36, 0.10  # um; 0.36 meets the Vn.2b array rule
CUT_LAYER = {("Metal2", "Metal3"): "Via2", ("Metal3", "Metal4"): "Via3", ("Metal4", "Metal5"): "Via4"}


def overlap(a, b):
    r = (max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3]))
    return r if r[0] < r[2] and r[1] < r[3] else None


class Bridges:
    def __init__(self, reader):
        self.block = reader.block
        self.tech = reader.tech
        self.layers = reader.layers
        self.dbu = reader.dbunits
        self.grid = self.tech.getManufacturingGrid()
        self.vias = 0

    def um(self, v):
        return int(round(v * self.dbu / self.grid)) * self.grid

    def box(self, swire, layer, r):
        odb.dbSBox_create(swire, self.layers[layer], r[0], r[1], r[2], r[3], "STRIPE")

    def via(self, swire, lower, upper, r):
        """Largest cut array inside overlap r, centered on it."""
        cut, sp, enc = self.um(CUT), self.um(CUT_SPACING), self.um(ENCLOSURE)
        w, h = r[2] - r[0] - 2 * enc, r[3] - r[1] - 2 * enc
        cols, rows = (w + sp) // (cut + sp), (h + sp) // (cut + sp)
        if cols < 1 or rows < 1:
            raise RuntimeError(f"{lower}-{upper} overlap {r} too small for a via")
        cl = CUT_LAYER[(lower, upper)]
        p = odb.dbViaParams()
        p.setBottomLayer(self.layers[lower])
        p.setCutLayer(self.layers[cl])
        p.setTopLayer(self.layers[upper])
        p.setXCutSize(cut)
        p.setYCutSize(cut)
        p.setXCutSpacing(sp)
        p.setYCutSpacing(sp)
        for side in ("XBottom", "YBottom", "XTop", "YTop"):
            getattr(p, f"set{side}Enclosure")(enc)
        p.setNumCutCols(cols)
        p.setNumCutRows(rows)
        v = odb.dbVia_create(self.block, f"b22_bridge_{cl}_{self.vias}")
        v.setViaGenerateRule(self.tech.findViaGenerateRule(f"{cl}_GEN_HH"))
        v.setViaParams(p)
        g = 2 * self.grid  # keep the array edges on the manufacturing grid
        cx = (r[0] + r[2]) // 2 // g * g
        cy = (r[1] + r[3]) // 2 // g * g
        odb.dbSBox_create(swire, v, cx, cy, "STRIPE")
        self.vias += 1

    def stripes(self, net, layer):
        out = []
        for sw in net.getSWires():
            for b in sw.getWires():
                if not b.isVia() and b.getTechLayer().getName() == layer:
                    out.append((b.xMin(), b.yMin(), b.xMax(), b.yMax()))
        return out

    def run(self):
        die = self.block.getDieArea()
        ext, wid = self.um(EXT), self.um(RISER)
        for bt in self.block.getBTerms():
            if bt.getSigType() not in ("POWER", "GROUND"):
                continue
            net = bt.getNet()
            terms = [
                (b.xMin(), b.yMin(), b.xMax(), b.yMax())
                for bp in bt.getBPins()
                for b in bp.getBoxes()
                if b.getTechLayer().getName() == "Metal2"
            ]
            west = [t for t in terms if t[0] == die.xMin()]
            north = [t for t in terms if t[3] == die.yMax()]
            if len(west) + len(north) != len(terms):
                # shortcut: only the W and N edges used by B22_A.def are handled
                raise RuntimeError(f"{bt.getName()}: terminal on an unsupported edge")
            sw = odb.dbSWire_create(net, "ROUTED")
            if west:
                x0 = die.xMin()
                for t in west:
                    r = (x0, t[1], x0 + ext, t[3])
                    self.box(sw, "Metal2", r)
                    self.box(sw, "Metal3", r)
                    self.via(sw, "Metal2", "Metal3", r)
                tgt = [s for s in self.stripes(net, "Metal5") if s[0] <= x0 + ext - wid]
                if not tgt:
                    raise RuntimeError(f"{net.getName()}: no Metal5 stripe reaches the west edge")
                lo, hi = min(t[1] for t in west), max(t[3] for t in west)
                s = min(tgt, key=lambda s: max(s[1] - hi, lo - s[3], 0))
                riser = (x0 + ext - wid, min(lo, s[1]), x0 + ext, max(hi, s[3]))
                self.box(sw, "Metal4", riser)
                for t in west:
                    self.via(sw, "Metal3", "Metal4", overlap(riser, (x0, t[1], x0 + ext, t[3])))
                self.via(sw, "Metal4", "Metal5", overlap(riser, s))
                print(f"{net.getName()}: {len(west)} west terminals to Metal5 stripe y {s[1] / self.dbu}-{s[3] / self.dbu}")
            if north:
                y1 = die.yMax()
                for t in north:
                    r = (t[0], y1 - ext, t[2], y1)
                    self.box(sw, "Metal2", r)
                    self.box(sw, "Metal3", r)
                    self.via(sw, "Metal2", "Metal3", r)
                tgt = [s for s in self.stripes(net, "Metal4") if s[3] >= y1 - ext + wid]
                if not tgt:
                    raise RuntimeError(f"{net.getName()}: no Metal4 stripe reaches the north edge")
                lo, hi = min(t[0] for t in north), max(t[2] for t in north)
                s = min(tgt, key=lambda s: max(s[0] - hi, lo - s[2], 0))
                bar = (min(lo, s[0]), y1 - ext, max(hi, s[2]), y1 - ext + wid)
                self.box(sw, "Metal3", bar)
                self.via(sw, "Metal3", "Metal4", overlap(bar, s))
                print(f"{net.getName()}: {len(north)} north terminals to Metal4 stripe x {s[0] / self.dbu}-{s[2] / self.dbu}")
        print(f"bridge vias placed: {self.vias}")


@click.command()
@click_odb
def cli(reader):
    Bridges(reader).run()


if __name__ == "__main__":
    cli()
