import std::io;
import ext::net::udp;
import stdlib;

fn void main(String[] args)
{
    if (args.len < 3) {
        io::printfn("Usage: %s port 'msg'", args[0]);
        io::printfn("default port: 9000");
        stdlib::exit(0);
    }
    UdpSocket s = udp::new()!!;
    s.sendto(args[2], "127.0.0.1", args[1].to_short())!!;
}
