#!/bin/bash
#########################################################################################
# This script was created to copy indices to another Mindbreeze Inspire appliance.
#
# IMPORTANT PRE-REQUISITES
#  1) Indices must be running on the source appliances
#  2) Script must be ran within the inspire container on the source
#  3) Configuration of the indices must be identical on both source and destination.
#     This can be done with snapshots ir exporting/importing the index XML configs
#     Files copied to same path on the destination as they are on the source
#  4) Indices must be disabled or mesnode stopped on the destination appliance.
#  5) The source server must be able to connect to the destination on TCP 22
#
#  Optional, add public key from source Inspire to authorized_keys on dest host server.
#   This avoids being prompted for a password when rsync'ing each index.
#
#  Use -h for HELP
#
# v1.1.1 - 2022-01-30 - ckayfish
#
#########################################################################################

DEST=""  # Destination hostname or IP
IPORTS=()                # An array of specific index ports. Use -i <#####> once or more
COPYFILES="false"        # Files are not copied by default. Use -c to copy
FORMAT="false"           # Use -f to display simple format
APPROVEEACH="false"      # Use -a to be prompted to approve
QUIET="false"            # Use -q to bypass prompts. Still prompt for each index with -a
SKIP="false"             # Use -s to skip the network test

helpout() { # Define help function for when -h is included in command line
   echo
   echo "Copy active indices from a source Inspire appliance to a destination"
   echo
   echo "Syntax: $0 -d <hostname> [-i <index_port>|-c|-f|-a|-q|-h]"
   echo "Options:"
   echo "   -d <HOST> - Set the hostname/IP of the (d)estination appliance."
   echo "   -i <PORT> - Specify (i)ndex port. Repeat for all desired indices."
   echo "                If no index port(s) specified, get all active from mesconfig."
   echo "   -c - (c)opy files to destination. Default is to not copy, show details only."
   echo "   -f - (f)ormat output simply for quick view of indices."
   echo "   -a - (a)pprove each index. Default is to act on all enabled indices."
   echo "   -q - (q)ueitly run to avoid prompts. (a) still respected if selected."
   echo "   -s - (s)kip network test to view index details without checking destination."
   echo "   -h - (h)elp info displayed if selected or unknown options used."
   echo
   echo "To only list all source indices: \"$ $0 -fqs\""
   echo "To copy all indices to the dest: \"$ $0 -d <FQDN/IP> -c\""
   echo "To copy a few specific  indices: \"$ $0 -d <FQDN/IP> -i <12335> -i <34567> -c\""
   echo "!!! INDICES MUST BE DISABLED, OR MESNODE STOPPED, ON DESTINATION SERVER !!!"
   echo
}

#Get command line options
while getopts d:i:cfaqsh flag ; do
    case "${flag}" in
        d) DEST=${OPTARG};;
        i) IPORTS+=(${OPTARG});;
        c) COPYFILES="true";;
		f) FORMAT="true";;
        a) APPROVEEACH="true";;
        q) QUIET="true";;
        s) SKIP="true";;
        *) helpout
           exit;;
    esac
done

timestamp() { # Create Timestamp function
  date +"%F_%T"
}
echo "  Use -h for (h)elp"

export PATH=/usr/bin:/opt/mindbreeze/bin #Include locations of exectables we will be running

# Perform network test unless (s)skip is seleced
if [[ $SKIP = "true" ]] ; then echo "  Skipping network test."; else
  # Confirm we can connect to the destination on TCP 22 as required by rsync
  timeout 3 bash -c "</dev/tcp/$DEST/22"
  if [ $? -ne 0 ]; then
    echo "  Cannot connect to \"$DEST\" on TCP 22. DNS or network failed."
    echo "  Set (d)estination hostname or IP using option -d <hostname/IP>"
        echo "  or use -s to (s)kip the network test to see local indices."
    echo
    exit
  else
    echo "  Confirmed connection on TCP 22 for \"$DEST\""
  fi
  # Prompt to confirm indices on destination server are disabled, or mesnode stopped, unless (q)uiet is selected
  # Inside test for (s)kip since copy is couterindicated by skipping the network test
  if [[ ! $QUIET = "true" ]] ; then
    echo "  IMPORTANT: Continue ONLY if indices are disabled, or mesnode stopped, on the destination server (check Services page)."
    read -p "Press 'y' if you are ready to proceed: " -n1 -r
    if [[ ! $REPLY =~ ^[Yy] ]]; then printf "\nExiting script\n"; exit; else echo; echo "$(timestamp) - Begin processing with destination: \"$DEST\""; echo; fi
  else
    echo "$(timestamp) - QUIET MODE"
  fi
fi


# Initialize variables counting indices and sizes
NUM_INDICES_FOUND=0
NUM_INDICES_COPIED=0
TOTALBYTES=0
TOTALBYTESCOPY=0
START_TIME=$(date +%s) # Time execution began, to compare against endtime to get total time

#Set array to port specified with arguments, or get all active ports from mesconfig
if [[ "$IPORTS" ]] ; then
  INDEXPORTS=${IPORTS[@]}
else
  INDEXPORTS=$(xmllint --xpath "//Index[@disabled='false' or not(@disabled)]/@bindport" /etc/mindbreeze/mesconfig.xml)
fi

# Loop through all active indices
for BINDPORT in $INDEXPORTS; do
  PORT=$(cut -d'"' -f2 <<< "$BINDPORT")
  name=""
  id=""
  indexpath=""
  echo "$(timestamp): Checking index on port $PORT"
  # Get index name, id, and path
  eval "$(xmllint --xpath "//Index[@bindport=$PORT]/@*[name()='indexpath' or name()='id' or name()='name' or name()='disabled']" /etc/mindbreeze/mesconfig.xml 2>/dev/null)"
  IDXPATH=$(if test -z "$indexpath"; then echo /data/servicedata/$id/index; else echo $indexpath; fi) # Find index directory path
  # Test if id found and index path exists
  if [ ! "$id" ]; then echo "  Index not found on port $PORT"; echo; continue
  else
    if [ ! -d "$IDXPATH" ]; then echo "  \"$IDXPATH\" is not a valid directory"; echo; continue
	else ((NUM_INDICES_FOUND++)); fi
  fi
  SIZEBYTES=$(du -s $IDXPATH | cut -f1)
  TOTALBYTES=$((TOTALBYTES + SIZEBYTES)) # Add number of bytes for this index to total bytes
  # If FORMAT option was selected, display simple format for index details.
  if [ $FORMAT == "true" ]; then printf "  Name: \"$name\" ID: \"$id\" Path: \"$IDXPATH\" Size: \"$(echo "scale=3;$SIZEBYTES / 1000000" | bc)GB\"\n"
  else 
     printf "  Name: $name\n  ID: $id\n  Path: $IDXPATH\n  Size: $(echo "scale=3;$SIZEBYTES / 1000000" | bc)GB\n" # Display index name, id, path and size
     echo "  Sync command: \"rsync -a $IDXPATH/ root@$DEST:/var/data/default/${IDXPATH:1}\"" # echo rsync command for user to see what's going on
  fi
  # IF APPROVEEACH is "true", prompt user for each index
  if [ "$APPROVEEACH" == "true" ]; then
    read -p "Press 'y' to copy index \"$name\": " -n1 -r
    if [[ ! $REPLY =~ ^[Yy] ]] ; then echo "  Skipping this index"; echo; continue; else echo "  Proceeding"; fi
  fi
  if [ "$COPYFILES" == "true" ] && [ "$SKIP" == "false" ]; then # Do not execute unless user requests it with variable/option
    if [ $FORMAT == "false" ]; then echo "$(timestamp) - Setting index to readonly"; fi
    mescontrol http://localhost:"$PORT" readonly  # Set index to readonly
	if [ $FORMAT == "false" ]; then mescontrol http://localhost:"$PORT" status; fi 
    echo "$(timestamp) - Syncing index \"$name\" to $DEST"
    rsync -a "$IDXPATH"/ root@"$DEST":/var/data/default/"${IDXPATH:1}" --delete
    TOTALBYTESCOPY=$((TOTALBYTESCOPY + SIZEBYTES)) # Add number of bytes for this index to total bytes copied
    ((NUM_INDICES_COPIED++))
    if [ $FORMAT == "false" ]; then echo "$(timestamp) - Setting index to read-write"; fi
    mescontrol http://localhost:"$PORT" readwrite # Set index to read/write
	if [ $FORMAT == "false" ]; then mescontrol http://localhost:"$PORT" status; fi 
  else
    if [ $FORMAT == "false" ]; then echo "$(timestamp) - (c)opy not selected or the network test was (s)kipped"; fi
  fi
  echo
done
echo "$(timestamp) - Found $NUM_INDICES_FOUND indices (size: $(echo "scale=3;$TOTALBYTES / 1000000" | bc)GB) and copied $NUM_INDICES_COPIED (size copied: $(echo "scale=3;$TOTALBYTESCOPY / 1000000" | bc)GB) in $(($(date +%s)-START_TIME)) seconds"
