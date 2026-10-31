# patches/common/ — retired

`01-nvidia-kernel-string-api.patch` (removed in the 615.78.08 port,
615-port ticket 04; recover via `git log --diff-filter=D -- patches/common/`)
worked around kernel string-API fallout on NVIDIA 610.43.03. NVIDIA fixed
every site upstream in 615.78.08 — verified against the `615.78.08` tag:

| 610 site (patch fixed)                          | 615 state                                            |
|-------------------------------------------------|------------------------------------------------------|
| `os-interface.c` `strncpy(buf, current->comm)`  | stock `strscpy()` call (`os-interface.c:775`)        |
| `os-interface.c` missing `<linux/string.h>`     | not needed by stock code (compiles untouched)        |
| `linux_nvswitch.c` regkey `strncpy`             | stock `memcpy(regkey_val, …)` (`linux_nvswitch.c:2141`) |
| `linux_nvswitch.c` `nvswitch_os_strncpy` returning `strncpy` | helper deleted (zero `strn?cpy` calls left in file) |
| `uvm_pmm_gpu.c` `chunk_split_cache` `strncpy`   | stock `snprintf` (`uvm_pmm_gpu.c:2822`)              |
| `nvidia-modeset-linux.c` `strncpy` helper       | deleted (zero `strn?cpy` calls in file)              |

Do not "restore" this patch: applying it to 615 rejects all hunks, and the
`build.sh` hard requirement for the file was removed together with it.
Driver-version pins live in `driver-pin.env` at repo root.
