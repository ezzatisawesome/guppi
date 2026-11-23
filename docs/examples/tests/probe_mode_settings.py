"""NON-ENERGIZING probe: the SAS's mode-dependent settings (sas1), the probable-short
guard's inputs, and what a battery-emulator read costs (batt1). Never turns an
output on; refuses to write to a channel whose output reads on.

Phase 1 only reads: each SAS channel's mode, priority, regulation state, and
every limit as the rack shows it now ("n/a" with why, not the *RST number,
for one its mode doesn't apply), the driver's setup order, and the time of a
streamed vs a fresh batt1 current read.

Phase 2 runs only with --param write_check=1, on channels whose output reads
off, and puts each one back as it found it: in Fixed mode it sets a current
limit at voltage priority, flips the priority to current and back, and checks
the rack wrote the limit back (and said so in the run log); then in SAS mode
it checks a scale before any curve is refused naming the fix.

    guppi run docs/public/examples/tests/probe_mode_settings.py
    guppi run docs/public/examples/tests/probe_mode_settings.py --param write_check=1

To confirm the instrument facts the driver's declarations rest on (outputs
off; each line prints the reply and the instrument's own errors):

    guppi scpi sas1 'OUTP? (@5)'                 # must be 0 before anything below
    guppi scpi sas1 'FUNC CURR,(@5)'
    guppi scpi sas1 'CURR:LIM 0.5,(@5)'          # accepted at current priority, or +315?
    guppi scpi sas1 'FUNC VOLT,(@5)'
    guppi scpi sas1 'CURR:LIM? (@5)'             # 0.102: the priority change reset it?
    guppi scpi sas1 'CURR:MODE SAS,(@5)'
    guppi scpi sas1 'CURR:SAS:SCAL 50,(@5)'
    guppi scpi sas1 'CURR:SAS:SCAL? (@5)'        # 100: ignored before a curve?
    guppi scpi sas1 'CURR:LIM 0.5,(@5)'          # accepted in SAS mode?
    guppi scpi sas1 'CURR:MODE FIX,(@5)'         # back to Fixed
"""

import time

import openhtf as htf
from guppi import param, plugs

SAS_CHANNELS = (5, 6)
WRITE_CHECK = param("write_check", 0)
SETTINGS = ("output", "mode", "priority_mode", "regulation", "current_limit",
            "current_limit_negative", "voltage_limit", "voltage_limit_low", "current_scale",
            "voltage_scale", "ocp_state")


@htf.measures(htf.Measurement("sas_read"))
@htf.plug(sas=plugs.SAS1)
def sas_modes(test, sas):
    """Each setting as the rack shows it, with why for the ones n/a in this mode."""
    test.logger.info("sas1 setup order: %s", " -> ".join(sas.setup_order))
    for ch in SAS_CHANNELS:
        for k in SETTINGS:
            name = f"{ch}.{k}"
            value = sas.read_now(name)
            why = sas.not_applicable(name)
            test.logger.info("sas1 %s = %s", name, f"n/a ({why})" if why else value)
    test.measurements.sas_read = True


@htf.measures(htf.Measurement("batt_read_ms"))
@htf.plug(batt=plugs.BATT1)
def batt_read_cost(test, batt):
    """A plug read from the stream vs one asked of the instrument."""
    t0 = time.monotonic()
    streamed = batt.measure_current(1)
    t1 = time.monotonic()
    fresh = batt.measure_current(1, fresh=True)
    t2 = time.monotonic()
    test.logger.info("batt1 measure_current: streamed %s in %.0f ms, fresh %s in %.0f ms",
                     streamed, (t1 - t0) * 1000, fresh, (t2 - t1) * 1000)
    test.measurements.batt_read_ms = round((t2 - t1) * 1000, 1)


@htf.measures(htf.Measurement("mode_checks"))
@htf.plug(sas=plugs.SAS1)
def sas_mode_writes(test, sas):
    """A priority round trip writes the limit back; a scale before a curve is refused."""
    if not WRITE_CHECK:
        test.logger.info("write check skipped (--param write_check=1 to run it)")
        test.measurements.mode_checks = "skipped"
        return
    done = []
    for ch in SAS_CHANNELS:
        if sas.read_now(f"{ch}.output"):
            test.logger.warning("ch%d output is on: not touching it", ch)
            continue
        mode, prio = sas.read_now(f"{ch}.mode"), sas.read_now(f"{ch}.priority_mode")
        tokens = {o.code: o.token for o in sas._fields_by_signal()[f"{ch}.mode"].options}
        prios = {o.code: o.token for o in sas._fields_by_signal()[f"{ch}.priority_mode"].options}
        try:
            sas.set_mode(ch, "FIX")
            sas.set_priority_mode(ch, "VOLT")
            held = sas.read_now(f"{ch}.current_limit")
            sas.set_current_limit(ch, held)                 # the value it holds: no change
            sas.set_priority_mode(ch, "CURR")
            test.logger.info("ch%d at current priority: current_limit %s", ch,
                             sas.not_applicable(f"{ch}.current_limit"))
            sas.set_priority_mode(ch, "VOLT")
            back = sas.read_now(f"{ch}.current_limit")
            test.logger.info("ch%d current_limit set %s, after a priority round trip %s "
                             "(the run log says if the rack wrote it back)", ch, held, back)
            sas.set_mode(ch, "SAS")
            try:
                sas.set_current_scale(ch, 50.0)
                test.logger.warning("ch%d: a scale before any curve was NOT refused", ch)
            except ValueError as e:
                test.logger.info("ch%d scale before a curve refused: %s", ch, e)
            done.append(ch)
        finally:
            sas.set_mode(ch, tokens.get(mode, "FIX"))
            if tokens.get(mode, "FIX") == "FIX":
                sas.set_priority_mode(ch, prios.get(prio, "VOLT"))
    test.measurements.mode_checks = ",".join(str(c) for c in done) or "none"


test = htf.Test(sas_modes, batt_read_cost, sas_mode_writes)
