#!/bin/sh

# mount host filesystem
mkdir -p /mnt/host
mount -t 9p -o trans=virtio host /mnt/host

# copy the libraries and demos
cd /mnt/host
cp -vat /usr out/ts-install/arm-linux/lib out/ts-install/arm-linux/bin

out/linux-arm-ffa-user/load_module.sh

# then run the demo
#ts-service-test -v
#ts-demo
