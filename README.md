# logd - High performance logging daemon in C3

## Key Features

* aggregating logs from multiple processes, multiple machines
* collecting logs via UDP Socket
* multiple category of logs, from multiple UDP ports
* daily/hourly rolling
* log mirroring to some other logd
* provides separate monitoring port

## How to use

```bash 
# clone logd
git clone https://github.com/nomota/logd-c3

# clone 'c3l' library manager
git clone https://github.com/konimarti/c3l
cd c3l
sudo make install

# back to logd-c3
cd logd-c3
c3l fetch https://github.com/nomota/ext.c3l

# build binary to build/logd & build/logd_test
make all

# run logd as debug mode
build/logd -debug

# on other terminal 
build/logd_test 9000 'test msg'

# you'll see a file like /tmp/LOG/TEST/20260219/34

# for a real mode, edit svc.conf

# run like this
build/logd -normal svc.conf
```