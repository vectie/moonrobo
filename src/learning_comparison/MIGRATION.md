# compare_dynamics.py

`comparison.mbt` and `cli/` implement the complete common-scale evaluation and report pipeline for three refitted models plus the initial model. Both held-out layouts are checked against every model, predictions use the initial model's state scale, and the report retains the original JSON schema and exact input/checkpoint SHA256.

Run after the machine is available:

```console
moon run src/learning_comparison/cli -- --initial initial.moon.json --corrected refitted-folder --validation validation.json.gz --test test.json.gz --output common-scale.json
```

The corrected folder contains `dynamics-seed-0.moon.json` through `dynamics-seed-2.moon.json`; when absent, corresponding `.pt` files are read through the restricted numeric Torch importer. The initial file accepts either format. Values use float64; numerical agreement with the Python float32 implementation has not been tested. Type checking only; this command was not run.
