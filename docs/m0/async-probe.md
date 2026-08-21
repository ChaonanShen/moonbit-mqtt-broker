# Native async runtime probe

The M0 probe targets `moonbitlang/async@0.20.6` on Linux x86_64 Native. It
exercises the runtime APIs the network broker will depend on:

- `@socket.TcpServer` on `127.0.0.1:0` and `@socket.Tcp::connect`;
- bounded `@async.Queue(kind=Blocking(1))` backpressure and close wake-up;
- `@async.sleep`, `@async.now`, task cancellation, and TaskGroup propagation;
- cancellation of a task blocked in `Tcp::read_some`;
- simultaneous dedicated reader and writer tasks on one TCP connection.

The tests use dynamic loopback ports, close every socket and listener, and use
one reader plus one writer per connection. Two concurrent reads or two
concurrent writes are deliberately excluded because the async socket contract
does not permit them.

Run with:

```bash
scripts/moon-docker.sh test --target native src/runtime_probe
```
