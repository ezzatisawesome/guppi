"""NON-ENERGIZING probe: SAS (sas1) and battery emulator (batt1) protection state
and trip cause. Never turns an output on, and only reads.

Which mode each SAS limit is accepted in: probe_mode_settings.py beside this
one, and the `guppi scpi` lines in its docstring.
"""

import openhtf as htf
from guppi import plugs

SAS_CHANNELS = (5, 6)
SAS_READS = ("output", "protection_tripped", "protection_cause", "mode", "priority_mode",
             "ocp_state", "ocp", "current_limit", "voltage_limit", "voltage_limit_low")


@htf.measures(htf.Measurement("sas_read"))
@htf.plug(sas=plugs.SAS1)
def sas_state(test, sas):
    """Every protection and limit setting asked of the instrument, plus the raw status bits."""
    for ch in SAS_CHANNELS:
        got = {k: sas.read_now(f"{ch}.{k}") for k in SAS_READS}
        test.logger.info("sas1 ch%d: %s; status bits %s", ch, got, sas.channel_conditions(ch))
    test.logger.info("sas1 error queue: %s", sas.read_errors())
    test.measurements.sas_read = True


@htf.measures(htf.Measurement("batt_read"))
@htf.plug(batt=plugs.BATT1)
def batt_state(test, batt):
    """The emulator's protection state and cause, asked of the instrument."""
    got = {k: batt.read_now(f"1.{k}") for k in ("output", "protection_tripped", "protection_cause")}
    test.logger.info("batt1: %s; faults %s; errors %s", got, batt.get_faults(1), batt.read_errors())
    test.measurements.batt_read = True


test = htf.Test(sas_state, batt_state)
