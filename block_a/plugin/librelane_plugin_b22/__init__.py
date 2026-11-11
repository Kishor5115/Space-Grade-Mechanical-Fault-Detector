# LibreLane plugin for the B22 Block A wrapper. Put block_a/plugin on PYTHONPATH.
import os

from librelane.steps import Step
from librelane.steps.odb import OdbpyStep


@Step.factory.register()
class PowerBridges(OdbpyStep):
    """
    Connects the Metal2 VDD/VSS terminals that the organizers' DEF template puts
    on the block edge to the PDN grid, which pdngen cannot reach on its own.
    """

    id = "B22.PowerBridges"
    name = "Power Terminal Bridges"

    def get_script_path(self):
        return os.path.join(os.path.dirname(__file__), "power_bridges.py")
