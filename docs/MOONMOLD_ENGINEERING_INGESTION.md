# MoonMold engineering ingestion

MoonRobo accepts only portable `engineering-model` artifacts derived from an
accepted editable-authoring parent through `modeled-from`. Presentation,
manufacturing, or loss-bearing transforms cannot enter the engineering lane.

Input is serialized MoonMold artifact+transform JSON and the currently accepted
editable-parent digest. Output retains geometry identity, digest, payload,
spatial conventions, transform, assumptions, unresolved gaps, and authority,
with `qualification_claimed: false`.

Quality gates require exact child identity/digest, current parent, lossless
engineering transform, MoonRobo consumer authorization, digital-artifact claim
ceiling, and explicit units/frame. This import is an engineering candidate;
MoonRobo qualification remains a separate process and cannot be inferred from
MoonMold.

The fixture is a byte-for-byte MoonMold portable export. No MoonMold source is
imported at runtime.

