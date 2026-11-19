# Secure Mode

This is a single plugin and has very specific function, not ready for everyone.

All it did is link the `secure-mode.toml` in your Umbriel config path to `/tmp/io.soloev/secure-mode/secure-mode.toml` and told Umbriel to reload.

Can be used as an interesting capsule on your bar.

`io.soloev/secure-mode`，Noctalia v5 / plugin API 46

Requires `python3` .

## IPC

```sh
noctalia msg plugin io.soloev/secure-mode:service all on
noctalia msg plugin io.soloev/secure-mode:service all off
noctalia msg plugin io.soloev/secure-mode:service all toggle
noctalia msg plugin io.soloev/secure-mode:service all restore
```

