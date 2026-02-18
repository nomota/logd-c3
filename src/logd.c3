// logd.c3
//
// High performance logging daemon
//
// * aggregating logs from multiple processes, multiple machines
// * collecting logs via UDP Socket
// * multiple category of logs, from multiple UDP ports
// * daily/hourly rolling
// * log mirroring to some other logd
// * provides separate monitoring port
//
// Author: nomota@mobigen.com, hiongun@gmail.com
// MIT License

module logd;

import std::io;
import std::collections;
import std::thread;

import ext::io::cfile;
import ext::io::dir;
import ext::regex;

import stdio;
import stdlib;
import unistd;
import string;
import netinet::in;
import sys::stat;
import time;
import poll;

import ext::hash::city;
import ext::net;

const String VERSION = "1.0";

typedef Socket = inline int;

fn uint Socket.hash(self) {
    ulong h1 = city::hash64((char*)&self, Socket.sizeof);
    uint h2 = (uint)h1;
    return h2;
}

fn bool Socket.equals(self, Socket other) {
    return (string::memcmp((void*)&self, (void*)&other, Socket.sizeof) == 0);
}

struct Globals {
    ushort flushduration; // seconds
    String logdir;
    HashMap{ushort,String} logports; // port to subdir(category) name 
    ushort monport;
    bool debug;
    time::Time curtime;
    HashMap{String,String} mirrorips;
    HashMap{UdpSocket,LogServer*} sockservers;
    HashMap{ushort,LogServer*} logservers;
    PollFd[] polls;
}

Globals g; // gloval vars

struct Msg {
    String ip; // sender ip
    ushort port; // sender port
    String msg;
}

fn void Msg.free(Msg* self)
{
    self.ip.free(mem);
    self.msg.free(mem);
    free(self);
}

struct LogServer {
    String subdir; // category name
    ushort port; // receiving UDP port 
    UdpSocket sock;
    cfile::File fh;
    List{Msg*} msgs;
}

struct MonServer {
    ushort port;
}

fn String bcat(char[] buf, String... args) @inline
{
    buf[0] = 0;
    foreach (arg: args) {
        string::strcat(buf.ptr, arg.ptr);
    }
    usz n = string::strlen(buf.ptr);
    return (String)buf[0..n-1];
}

fn String sftime(char[] buf, String format, time::Time t) @inline
{
    char[64] formatbuf;
    formatbuf[0:format.len] = format[0:format.len];
    formatbuf[format.len] = 0;
    
    time::Tm tm;
    usz n = time::strftime(buf.ptr, buf.len, &formatbuf[0], time::localtime_r(&t, &tm));
    return (String)buf[0..n-1];
}

fn String sprf(char[] buf, String format, args...) @format(1) @inline
{
    DString str; str.init(mem);
    defer str.free();
    str.appendf(format, ...args);

    String s = str.str_view();
    buf[0:s.len] = s[0:s.len];
    
    return (String)buf[0..s.len-1];
}

macro void print(String fmt, args...) @format(0)
{
    io::printfn(fmt, args);
}

macro void warn(String fmt, args...)
{
    io::printf("%s,%s: ", $$FILE, $$LINE); io::printfn(fmt, ...args);
}

macro void dbg(String fmt, args...)
{
    if (g.debug) io::printf("%s,%s: ", $$FILE, $$LINE); io::printfn(fmt, ...args);
}

fn void do_flush(LogServer* logserver)
{
    char[128] pathbuf;
    String logpath = bcat(&pathbuf, g.logdir, "/", logserver.subdir);
    dbg("logpath: %s", logpath);
    
    g.curtime = time::time(null);

    char[9] tbuf1;
    String today = sftime(&tbuf1, "%Y%m%d", g.curtime);

    char[3] hbuf;
    String curhour = sftime(&hbuf, "%H", g.curtime);

    char[11] tbuf2;
    String readabletime = sftime(&tbuf2, "%Y:%m:%d", g.curtime);

    char[128] todaybuf;
    String todaydir = bcat(&todaybuf, logpath, "/", today); 
    
    char[128] filebuf;
    String logfile = bcat(&filebuf, logpath, "/", today, "/", curhour);
    dbg("logfile: %s", logfile);
    
    if (! cfile::exists(logfile)) {;
        dir::make_dir(todaydir, true);
        if (! dir::exists(todaydir)) {
            warn("mkdir logpath/today failed");
            stdlib::exit(0);
        }

        if (logserver.fh.fp != null) {
            logserver.fh.close();
            logserver.fh.fp = null;
        }

    
        cfile::File? fh = cfile::open(logfile, "a+");
        if (catch err = fh) {
            warn("fopen(%) failed:%s", logfile, err);
            return;
        }
        logserver.fh = fh;
    }

    if (logserver.fh.fp == null) {
        // if there exists the log file, but not open
        // -- perhaps the daemon has been dead. Need to open it again

        cfile::File? fh = cfile::open(logfile, "a+");
        if (catch err = fh) {
            warn("fopen(%) failed:%s", logfile, err);
            return;
        }
        logserver.fh = fh;
    }

    foreach (msg: logserver.msgs) {
        char[2048] linebuf;
        String line = bcat(&linebuf, readabletime, " ", msg.msg, "\n");
        dbg("%s", line);
        
        usz? n = logserver.fh.write(line);
        if (catch err = n) {
            warn("write failed:%s", err);
        }
        msg.free();
    }

    logserver.msgs.clear();

    logserver.fh.flush();
}


fn void handle_read(LogServer* logserver)
{
    UdpSocket sock = (UdpSocket)logserver.sock;   
    
    char[2000] buf;
    char[64] ip;
    ushort port;
    usz? n = sock.recvfrom(&buf, &ip, &port);
    if (catch err = n) {
        warn("sock.read error");
        return;
    }
    
    Msg* msg = mem::alloc(Msg);
    msg.ip = ((String)ip[0..n-1]).copy(mem);
    msg.port = port;
    msg.msg = ((String)buf[0:n]).trim().copy(mem);

    dbg("from %s:%d '%s'", msg.ip, msg.port, msg.msg);
    
    logserver.msgs.push(msg);
    
    if (g.mirrorips.has_key(logserver.subdir)) {
        String? mirrorip = g.mirrorips[logserver.subdir];
        if (catch err = mirrorip){
            warn("mirrorips key err: %s\n", err);
            return;
        }
        ushort mirrorport = logserver.port;
        
        (void)sock.sendto(buf[0:n], mirrorip, mirrorport);
    }
}

/*
fn String? readline(InStream* in, char[] buf)
{
    for (usz i = 0; i < buf.len, i++) {
        usz? c = in.read_byte(buf[i..i]);
        if (catch err = c) {
            return err?;
        }
        if (buf[i] == '\n') {
            return (String)buf[0..i];
        }
    }
    return (String)buf;
}
*/

fn void write(TcpSocket out, String line)
{
    (void)out.write(line);
}

fn bool starts(String a, String b)
{
    return a.starts_with(b);
}

fn int handle_mon(void* arg) // thread
{
    MonServer* monserver = (MonServer*)arg;
    
    TcpSocket? ssock = tcp::new_listen(monserver.port);
    if (catch err = ssock) {
        warn("%s", err);
        return -1;
    }
    defer (void)ssock.close();
    
    while (true) {
        TcpSocket? sock = ssock.accept();
        if (catch err = sock) {
            warn("accept err: %s", err);
            continue;
        }
    
        dbg("sock accepted");
        
        char[2048] buf;
        String line = sprf(&buf, "+OK logd-%s\n", VERSION);
        usz? n = sock.write(line);
        if (catch err = n) {
            warn("sock.write failed: %s", err);
            continue;
        }
        
        while (true) {
            isz? nn = sock.readline(&buf);
            if (catch err = nn) {
                warn("sock.read failed: %s", err);
                break;
            }
            
            String cmd = (String)buf[0:nn];
            
            if (starts(cmd, "quit")) {
                write(sock, "+OK quit\n");
                break;
            }
            
            if (starts(cmd, "help")) {
                write(sock, "+OK help text follows\n");
                write(sock, "* help\n");
                write(sock, "* quit\n");
                write(sock, "* version\n");
                write(sock, "* stat\n");
                write(sock, "+OK done\n");
                continue;
            }
    
            if (starts(cmd, "version")) {
                write(sock, sprf(&buf, "+OK version: %s\n", VERSION));
                continue;
            }
        
            if (starts(cmd, "stat")) {
                write(sock, "-ERR stat not yet implemented.\n");
                continue;
            }

            write(sock, sprf(&buf, "-ERR unknown command: %s\n", cmd));
        }
    
        dbg("sock closing");
    
        (void)sock.close();
    }
}

fn void main_loop()
{
    time::Time lastflushtime = time::time(null); // remembers time of the last flush

    while (true) {
        g.curtime = time::time(null);

        warn("inner loop, poll()");
        int n = poll::poll(g.polls, g.polls.len, 20000);
        if (n < 0) {
            warn("poll failed");
            continue;
        }
        
        for (usz i = 0; i < g.polls.len; i++) {
            UdpSocket s = (UdpSocket)g.polls[i].fd;
            short e = g.polls[i].revents;
            if (e & poll::POLLIN) { // read ready
                LogServer* logserver = g.sockservers[s]!!;
                handle_read(logserver);
                continue;
            }
            if (e & poll::POLLOUT) { // write ready
                // do write on sock
                // usz? n = sock.write(buffer[]);
            }
            if (e & (poll::POLLERR | poll::POLLHUP)) { // socke is error
                // do error handling on sock
                // (void) sock.close();
                // remove sock from polls
            }
        }


        if ((g.curtime - lastflushtime) >= g.flushduration) 
        {
            g.logservers.@each(; p, logserver) 
            {
                // LogServer* logserver = g.logservers[p];
                if (logserver.msgs.len() > 0)
                {
                    do_flush(logserver);
                }
            };

            lastflushtime = g.curtime;
        } 
    }
}

fn void run_log_d()
{
    dbg("flush duration: %d sec", g.flushduration);
    
    MonServer* monserver = mem::alloc(MonServer); 
    monserver.port = g.monport;
    
    Thread thr; thr.create(&handle_mon, (void*)monserver)!!;
    defer {
        thr.join();
        free(monserver);
    };
    
    dbg("Run monserver on port:%d", monserver.port);

    g.logports.@each(; port, subdir) 
    {
        LogServer* logserver = mem::alloc(LogServer);
        
        logserver.port = port;
        logserver.subdir = subdir;
        
        UdpSocket? ssock = udp::new_bind(port);
        if (catch err = ssock) {
            warn("udp::new failed: %s", err);
            (void)stdlib::exit(1);
            return;
        }
        
        logserver.sock = ssock;
        
        dbg("waiting port:%d %s", port, subdir);

        g.logservers[port] = logserver;
        g.sockservers[ssock] = logserver;
        
    };

    PollFd[] polls = mem::alloc_array(PollFd, g.logports.len());
    g.polls = polls;
    
    foreach(i, sock: g.sockservers.key_iter()) {
        g.polls[i].fd = (int)sock;
        g.polls[i].events = poll::POLLIN; // SUBSCRIBE_WRITE;
    }
    
    main_loop();
}

fn void? read_config(String conf)
{
    if (! cfile::exists(conf)) {
        warn("read_conf(%s) failed", conf);
        return;
    }
    
    cfile::File? fp = cfile::open(conf, "r");
    if (catch err = fp) {
        warn("fopen(%s) failed:%s", conf, err);
        return;
    }
    defer fp.close();
    
    while (true) {
        char[1024] buf;
        usz? n = fp.readline(&buf);
        if (catch err = n) {
            break;
        }
        String line = (String)buf[0:n];
        line = line.trim();
        
        if (starts(line, "LOG_DIR ")) {
            String logdir = line[8..];
            g.logdir = logdir.copy(mem);
            dbg("LOG_DIR: %s", logdir);
            continue;
        }
            
        if (starts(line, "LOG_PORT ")) {
            Splitter iter = line[9..].tokenize(" ");
            while (try kv = iter.next()) {
                usz? idx = kv.index_of_char(':');
                if (catch err = idx) {
                    warn("format error. ':' not found: %s", kv);
                    continue;
                }
                
                String subdir = kv[0..idx-1];
                ushort? port = kv[idx+1..].to_ushort();
                if (catch err = port) {
                    warn("format error");
                    continue;
                }
                g.logports[port] = subdir.copy(mem);
            }
        }
        
        if (starts(line, "LOG_MIRROR ")) {
            Splitter iter = line[11..].tokenize(" ");
            while (try kv = iter.next()) {
                usz? idx = kv.index_of_char(':');
                if (catch err = idx) {
                    warn("format error. ':' not found: %s", kv);
                    continue;
                }
                
                String subdir = kv[0..idx-1];
                String ip = kv[idx+1..];
                g.mirrorips[subdir.copy(mem)] = ip.copy(mem);
            }
        }
        
        RegEx* r_dur = regex::new_compile(mem, `^FLUSH_DURATION (\d+)`)!;
        if (r_dur.match(line)! > 0) {
            ushort? duration = r_dur.group(1).s.to_ushort();
            if (catch err = duration) {
                warn("format error");
                continue;
            }
            g.flushduration = duration;
        }
        
        if (starts(line, "MON_PORT ")) {
            ushort? monport = line[9..].to_ushort();
            if (catch err = monport) {
                warn("format error");
                continue;
            }
            g.monport = monport;
        }
    }
}

fn void main(String[] args)
{
    if (args.len < 2) {
        io::printfn("Usage: %s -debug|-normal|-version [svc.conf]", args[0]);
        stdlib::exit(0);
    }

    if (args[1] == "-version") {
        io::printfn("VERSION: %s", VERSION);
        stdlib::exit(0);
    }
    
    if (args[1] == "-debug") {
        g.debug = true;
    }

    if (args[1] == "-normal") {
        g.debug = false;
    }

    String conf = "./svc.conf";
    if (args.len > 2) {
        conf = args[2];
    }
    
    g.logdir = "/tmp/LOG";
    g.logports[9000] = "TEST";
    g.monport = 9000;
    g.flushduration = 1;
    
    read_config(conf)!!;

    if (g.debug) {
        run_log_d();
        stdlib::exit(0);
    }
    
    if (unistd::fork() == 0) {
        if (unistd::fork() == 0) {
            run_log_d();
        }
        stdlib::exit(0);
    }
}
