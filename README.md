# passthroughfs

## test it

Create mount directory
```
mkdir /mnt/rf
```

Create backend directory
```
mkdir /root/backend
```
backend dir must be empty

Run it
```
nim c -r main.nim
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

Verify the file exist in backend dir and content is valid
```
cat /root/backend/hello.txt
```
