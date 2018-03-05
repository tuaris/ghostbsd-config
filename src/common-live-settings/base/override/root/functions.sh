#!/bin/sh
# Functions we source for starting the install / live mode
###########################################################

# Function which simply enables plain dhcp on all detected nics
# and creates the wlan[0-9] entries for wireless devices

detect_x()
{
  # First check if we are running as a VirtualBox guest
  pciconf -lv | grep -q "VirtualBox"
  if [ $? -eq 0 ] ; then cp /root/cardDetect/xorg.conf.virtualbox /etc/X11/xorg.conf ; return; fi

  # Try the second card, since many optimus / amd hybrids have Intel on secondary
  cfg_card_busid "1"

}

cfg_card_busid()
{
  whichcard="$1"

  # This script will manually set BusID for the first or second vgapciX device
  # For some reason in 10.0, it no longer auto-probes for different VGA devices :(
  inCard=0
  pciconf -lv > /tmp/.pciconf.$$
  while read line
  do
    echo $line | grep -q "^vgapci"
    if [ $? -eq 0 ] ; then
       curCard=`echo $line | cut -d "@" -f 1 | sed 's|vgapci||g'`
       busID="`echo $line | cut -d ':' -f 2-4`"
       inCard=1
       continue
    fi

    echo $line | grep -q "subclass"
    if [ $? -eq 0 ] ; then inCard=0; continue; fi

    if [ $inCard -eq 1 ] ; then
       echo $line | grep -q "vendor"
       if [ $? -eq 0 ]; then
          case $curCard in
             0) card1=`echo $line | cut -d "'" -f 2`
                card1bus="$busID"
                ;;
             1) card2=`echo $line | cut -d "'" -f 2`
                card2bus="$busID"
                ;;
             *) ;;
          esac
       fi
    fi
  done < /tmp/.pciconf.$$
  rm /tmp/.pciconf.$$

  # Check if we need to "flip" the cards, I.E. the Intel video should be the card #1, all others #2
  echo "$card2" | grep -q -i -e "intel"
  if [ $? -eq 0 ] ; then
     tmpCard="$card1"
     tmpCardBus="$card1bus"
     card1="$card2"
     card1bus="$card2bus"
     card2="$tmpCard"
     card2bus="$tmpCardBus"
  fi

  # Which card are we configuring
  if [ "$whichcard" = "1" ] ; then
    cfgCard="$card1"
    cfgCardBusID="$card1bus"
  else
    cfgCard="$card2"
    cfgCardBusID="$card2bus"
  fi

  # No detected, return 1
  if [ -z "$cfgCard" ] ; then return 1; fi

  # Is this an Intel chipset?
  echo "$cfgCard" | grep -q -i -e "intel"
  if [ $? -eq 0 ] ; then
     driver="modesetting"
  fi
  echo "$cfgCard" | grep -q -i -e "nvidia"
  if [ $? -eq 0 ] ; then
     driver="nvidia"
  fi

  # Found a card, lets try an xorg config for it
  cp /root/cardDetect/XF86Config.default /etc/X11/xorg.conf
  if [ -n "$driver" ] ; then
    echo "
Section \"Device\"
        Identifier      \"Card0\"
        Driver          \"$driver\"
        BusID           \"${cfgCardBusID}\"
EndSection
  " >> /etc/X11/xorg.conf
  else
    echo "
Section \"Device\"
        Identifier      \"Card0\"
        BusID           \"${cfgCardBusID}\"
EndSection
  " >> /etc/X11/xorg.conf
  fi

  return 0
}

start_default_xorg()
{
  ATTEMPT=0

  # Try bringing up X now
  startx

  # If we have a success, we can end here
  if [ -e "/tmp/.xstarted" ]; then
    return 0
  else
    # Couldn't start a valid xorg session... Boo :-(
    echo "ERROR: Failed to start X with automatic settings"
    echo "[Press Enter to Continue]"
    read tmp
  fi
  return 1
}

start_xorg()
{

  # Determine what modules we may need to load
  sh /etc/ghostbsd-video.sh

  # Allow time for ghostbsd-video.sh to load modules if needed
  sleep 5

  ATTEMPT=0

  # Try bringing up X now
  startx
  # If we have a success, we can end here
  if [ -e "/tmp/.xstarted" ]; then return 0; fi
  # Run X Now
  while :
  do
      case $ATTEMPT in
        0) # Lets try again with the primary video card specifically
          echo "Looking for primary video card..."
          rm /etc/X11/xorg.conf 2>/dev/null
          detect_x
            ;;
        1) # Lets try again with a secondary video card
           echo "Looking for secondary / optimus video card..."
            rm /etc/X11/xorg.conf 2>/dev/null
            cfg_card_busid "2"
            ;;
        2) # Try the Intel driver, since nvidia/vesa will fail on optimus cards
             echo "Trying Intel-only driver..."
            cp /root/cardDetect/XF86Config.modesetting /etc/X11/xorg.conf
            ;;
        3) echo "Trying VESA driver..."
            rm /etc/X11/xorg.conf
            cp /root/cardDetect/XF86Config.compat /etc/X11/xorg.conf
            ;;
        4) if [ `sysctl -n machdep.bootmethod` = "UEFI" ] ; then
              # Last but not least, if we are on UEFI we can always try SCFB
              echo "Trying SCFB - UEFI driver..."
              cp /root/cardDetect/XF86Config.scfb /etc/X11/xorg.conf
            else
              break
            fi
          ;;

        *) break ;;
        esac

    ATTEMPT=$(expr $ATTEMPT + 1)
  done

  # Couldn't find a valid Xorg config.. Boo :(
  echo "ERROR: Failed to start X..."
  echo "Dropping to failsafe console... Edit /etc/X11/xorg.conf, and run #startx to bring up the GUI."
  echo "[Press Enter to Continue]"
  read tmp
  /bin/sh
}

rtn()
{
   echo "Press ENTER to continue"
   read tmp
}

restamp_grub_install()
{
  clear
  mount | grep -q "on /mnt"
  if [ $? -ne 0 ] ; then
     zpool_import "nochroot"
     if [ $? -ne 0 ] ; then
        echo "Failed importing pool! Please import a pool before doing grub-install."
        rtn
        return
     fi
  fi

  # Copy over the installer version of beadm
  cp /root/beadm.install /mnt/root/beadm.install
  if [ $? -ne 0 ] ; then
     echo "Failed copying beadm.install..."
     rtn
     return 1
  fi

  # Run the grub restamp now
  chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  if [ $? -ne 0 ] ; then
     echo "Failed running grub-mkconfig..."
     rm /mnt/root/beadm.install
     rtn
     return 1
  fi

  # Remove installer version of beadm.install
  rm /mnt/root/beadm.install
  rtn

  return 0
}
