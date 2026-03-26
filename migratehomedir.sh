#!/bin/bash
set -e

# Sprawdź root
if [ "$EUID" -ne 0 ]; then
    echo "Uruchom jako root: sudo $0"
    exit 1
fi

echo "=== Migracja /home na inny dysk ==="
echo ""

# Pokaż dostępne partycje z rozmiarami
echo "Dostępne partycje:"
echo "-------------------"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID,PARTUUID | grep -v "^loop"
echo ""

# Pobierz listę partycji (bez aktualnie zamontowanych jako / i /home)
mapfile -t PARTITIONS < <(lsblk -rpo NAME,MOUNTPOINT | awk '$2=="" {print $1}')

if [ ${#PARTITIONS[@]} -eq 0 ]; then
    echo "Brak wolnych (niezamontowanych) partycji!"
    exit 1
fi

echo "Wybierz docelową partycję dla /home:"
select PART in "${PARTITIONS[@]}"; do
    if [ -n "$PART" ]; then
        echo "Wybrano: $PART"
        break
    else
        echo "Nieprawidłowy wybór, spróbuj ponownie."
    fi
done

# Pobierz UUID i PARTUUID wybranej partycji
PART_UUID=$(blkid -s UUID -o value "$PART")
PART_PARTUUID=$(blkid -s PARTUUID -o value "$PART")
PART_FSTYPE=$(blkid -s TYPE -o value "$PART")

echo ""
echo "Partycja : $PART"
echo "UUID     : $PART_UUID"
echo "PARTUUID : $PART_PARTUUID"
echo "Typ FS   : $PART_FSTYPE"
echo ""

# Zapytaj o format jeśli nie ext4
if [ "$PART_FSTYPE" != "ext4" ]; then
    read -rp "Partycja nie jest ext4 (jest: $PART_FSTYPE). Sformatować jako ext4? [t/N]: " FORMAT
    if [[ "$FORMAT" =~ ^[tT]$ ]]; then
        echo "Formatowanie $PART jako ext4..."
        mkfs.ext4 "$PART"
        PART_UUID=$(blkid -s UUID -o value "$PART")
        PART_PARTUUID=$(blkid -s PARTUUID -o value "$PART")
    else
        echo "Anulowano."
        exit 1
    fi
fi

read -rp "Kontynuować migrację /home na $PART? [t/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[tT]$ ]]; then
    echo "Anulowano."
    exit 1
fi

TEMP_MOUNT="/mnt/migrate_home_tmp"
OLD_ROOT_MOUNT="/mnt/oldroot_tmp"

echo ""
echo "=== [1/6] Montowanie $PART pod $TEMP_MOUNT ==="
mkdir -p "$TEMP_MOUNT"
mount "$PART" "$TEMP_MOUNT"

echo "=== [2/6] Kopiowanie /home na $PART ==="
rsync -av --progress /home/ "$TEMP_MOUNT"/

echo "=== [3/6] Aktualizacja /etc/fstab ==="
# Usuń ewentualną starą linię z tą partycją
sed -i "\|$PART|d" /etc/fstab
if [ -n "$PART_PARTUUID" ]; then
    echo "PARTUUID=$PART_PARTUUID  /home  ext4  defaults  0  2" >> /etc/fstab
else
    echo "UUID=$PART_UUID  /home  ext4  defaults  0  2" >> /etc/fstab
fi
echo ""
echo "Nowy /etc/fstab:"
cat /etc/fstab

echo ""
echo "=== [4/6] Odmontowanie $TEMP_MOUNT i montowanie jako /home ==="
umount "$TEMP_MOUNT"
rmdir "$TEMP_MOUNT"
mount /home

echo "=== [5/6] Weryfikacja - zawartość nowego /home ==="
ls /home/

echo "=== [6/6] Usuwanie starego /home z sda1 ==="
mkdir -p "$OLD_ROOT_MOUNT"
mount --bind / "$OLD_ROOT_MOUNT"
rm -rf "$OLD_ROOT_MOUNT"/home/*
umount "$OLD_ROOT_MOUNT"
rmdir "$OLD_ROOT_MOUNT"

echo ""
echo "=== Gotowe! ==="
df -h /
df -h /home
