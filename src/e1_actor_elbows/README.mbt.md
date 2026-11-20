# E1 constrained actor elbows

This explicit controller adapter permits SDK slots 3 and 14 to follow fresh
actor predictions. All other complete motor records remain equal to the captured
hold. Configuration supplies the position envelope, speed limit, response time
and engagement time. Position bounding and command filtering change the deployed
controller and must be evaluated with the actor, rather than represented as an
unchanged whole-body policy. Baseline and return phases have no model authority;
an inference failure must terminate the owner instead of selecting a preset.
