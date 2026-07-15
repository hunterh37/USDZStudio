"""Strip Animations — freeze time-sampled attributes to a static pose.

Many AR/ecommerce USDZ assets ship as static props but still carry animation
time samples from the DCC that authored them — wasted bytes and, worse,
unexpected motion in AR Quick Look. This bakes every time-sampled attribute
down to a single default value sampled at one frame and clears the samples.

Mutating. Operates on the selection if any, else the whole stage.
"""

from _harness import begin, finish

MANIFEST = {
    "name": "Strip Animations",
    "description": "Bake time-sampled attributes to a static pose.",
    "mutates": True,
    "args": [
        {"name": "frame", "type": "float", "default": None,
         "help": "Frame to freeze on (default: stage startTimeCode)."},
    ],
}


def main():
    ctx = begin(globals(), MANIFEST)
    stage = ctx.stage
    frame = ctx.args.frame
    if frame is None:
        frame = stage.GetStartTimeCode() if stage.HasAuthoredTimeCodeRange() else 0.0

    baked = 0
    for prim in ctx.prims():
        for attr in prim.GetAttributes():
            if attr.GetNumTimeSamples() <= 0:
                continue
            value = attr.Get(frame)
            attr.Clear()                 # drop all time samples on this spec
            if value is not None:
                attr.Set(value)          # re-author as a static default
            baked += 1

    # Collapse the stage's animation range so nothing thinks it still animates.
    stage.ClearMetadata("timeCodesPerSecond")
    stage.SetStartTimeCode(frame)
    stage.SetEndTimeCode(frame)

    ctx.app.log("froze %d animated attribute(s) at frame %g" % (baked, frame))
    finish(ctx)


if __name__ == "__main__" or globals().get("stage") is not None:
    main()
