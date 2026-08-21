///|
suberror CliError {
  CliError(String)
} derive(Debug)

///|
async fn main {
  let args = @env.args()
  let mut listen = "127.0.0.1:1883"
  let mut max_packet_size = 1048576
  let mut once = false
  let mut index = 1
  while index < args.length() {
    match args[index] {
      "--listen" => {
        if index + 1 >= args.length() {
          raise CliError("--listen requires HOST:PORT")
        }
        listen = args[index + 1]
        index = index + 2
      }
      "--max-packet-size" => {
        if index + 1 >= args.length() {
          raise CliError("--max-packet-size requires a positive integer")
        }
        max_packet_size = @string.parse_int(args[index + 1]) catch {
          _ => raise CliError("invalid --max-packet-size")
        }
        if max_packet_size < 2 {
          raise CliError("--max-packet-size must be at least 2")
        }
        index = index + 2
      }
      "--once" => {
        once = true
        index = index + 1
      }
      value => raise CliError("unknown argument: " + value)
    }
  }
  @server.run(listen, max_packet_size, once)
}
