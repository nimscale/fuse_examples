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

Write something to mounted dir
```
echo "hallo" > /mnt/rf/hello.txt
```

Verify the file exist in mounted dir
```
ls /mnt/rf

# read support will follow
```

Verify the file exist in backend dir and content is valid
```
cat /root/backend/hello.txt
```
