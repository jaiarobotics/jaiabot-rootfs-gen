#!/bin/bash

# calculate the terminal size for whiptail (WT)
function calc_wt_size() {
  WT_HEIGHT=$(tput lines)
  WT_WIDTH=$(tput cols)
  WT_MENU_HEIGHT=$((${WT_HEIGHT} - 8))
}

# convert array of values into an array suitable for whiptail menu
function array_to_wt_menu() {
  local input=("$@")
  WT_ARRAY=()
  for i in "${!input[@]}"
  do
     WT_ARRAY+=("${input[$i]}")
     WT_ARRAY+=("")
  done
}

# draw a GUI menu of options for the user using whiptail
# return choice in ${WT_CHOICE}
function run_wt_menu() {
   local title=$1
   local menu=$2
   shift 2
   local input=("$@")
   calc_wt_size
   array_to_wt_menu "${input[@]}"
   
   # insert stdout from the subshell directly in the controlling /dev/tty
   # so that we don't try to log any of the whiptail output
   WT_CHOICE=$(set -x; whiptail --title "$title" --menu "$menu" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT "${WT_ARRAY[@]}" --output-fd 5 5>&1 1>/dev/tty)
   echo "User chose: $WT_CHOICE"
}

# draw a GUI menu for entering a password
# return password in ${WT_PASSWORD}
function run_wt_password() {
   local title=$1
   local text=$2
   calc_wt_size
   
   WT_PASSWORD=$(set -x; whiptail --title "$title" --passwordbox "$text" $WT_HEIGHT $WT_WIDTH --output-fd 5 5>&1 1>/dev/tty)
   echo "User entered password: ****************"
}

# draw a GUI menu for entering a text string
# return text in ${WT_TEXT}
function run_wt_inputbox() {
   local title=$1
   local text=$2
   calc_wt_size
   
   WT_TEXT=$(set -x; whiptail --title "$title" --inputbox "$text" $WT_HEIGHT $WT_WIDTH --output-fd 5 5>&1 1>/dev/tty)
   echo "User entered: ${WT_TEXT}"
}

# draw a GUI box asking the user a YES/NO
# question. Return 0 if YES, 1 if NO
function run_wt_yesno() {
   local title=$1
   local text=$2
   calc_wt_size
   if (set -x; whiptail --title "$title" --yesno "$text" $WT_HEIGHT $WT_WIDTH > /dev/tty); then
      echo "User chose YES"
      return 0
   else 
      echo "User chose NO"
      return 1
   fi
}
