# passthroughfs

## implemented syscall

- getattr
- open
- read
- readdir
- mkdir
- lookup
- create
- write

## TODO

- other syscalls
- mount dir still hardcoded

## test it

Create mount directory
```
mkdir /mnt/rf
```

Run it
```
nim c -r memfs.nim
```

Write something to mounted dir
```
echo "hallo" > /mnt/rf/hello.txt
mkdir /mnt/rf/testdir
```

Verify the file exist in mounted dir and read it
```
ls /mnt/rf
cat /mnt/rf/hello.tx
```
