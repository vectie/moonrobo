"""Record original SMC's loaded code AFTER its unchanged update has finished.

Do not wrap external kernels or disable frontend caches. Reading launchers only
after backward avoids changing the graph selected for the reference update.
"""
import hashlib
import json
import os
from pathlib import Path
from actor_boundary_probe_a import main

main()
from torch._inductor.codecache import PyCodeCache
root=Path(os.environ["MOONROBO_SHARED_OUTPUT"])
folder=root/"loaded-code"
folder.mkdir()
records={}
for module in PyCodeCache.modules:
    path=Path(module.__file__)
    if not path.is_file(): continue
    target=folder/path.name
    if not target.exists(): target.write_bytes(path.read_bytes())
    kernels={name:dict(configs=[str(l.config) for l in kernel.launchers])
             for name,kernel in vars(module).items() if name.startswith("triton_") and hasattr(kernel,"launchers")}
    records[path.name]=dict(path=str(path),copy=str(target.relative_to(root)),
                           sha256=hashlib.sha256(target.read_bytes()).hexdigest(),smc_loaded_kernels=kernels)
(root/"loaded-code.json").write_text(json.dumps(records,indent=2))
