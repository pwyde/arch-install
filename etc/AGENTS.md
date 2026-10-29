# AGENTS.md: etc/

Configuration installed to the same path under `/etc`, except `vim/xdg.vim`,
which is appended to `/etc/vimrc`. The root [AGENTS.md](../AGENTS.md)
applies as well.

- `sudoers.d/`: a drop-in that fails `visudo -cf` disables sudo on the
  installed system.
- `cmdline.d/` is the source of the kernel command line. `base-install.sh`
  embeds it in the UKI and mirrors it into `/etc/default/limine`; a new file
  is added to `CMDLINE_FILES`.
- `ssh/`, `sudoers.d/`, `pam.d/`, `sysctl.d/6*-hardening.conf` and
  `systemd/coredump.conf.d/` are security-relevant: a change there is
  reflected in SECURITY.md.
