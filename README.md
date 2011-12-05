# Dirty MySQL Active/Passive Auto-installer
Major Hayden

## What is required?
* two Debian Squeeze VM's or physical boxes
* network connectivity between both nodes
* a virtual IP address and hostname for both nodes to share
* ruby needs to be installed but no gems are required

## How do I use it?
* clone this repository onto both nodes
* adjust the config.yml so that it matches your cluster's configuration
* run the script on both nodes

There are certain sections of the script where it will be waiting on the other node to do something, so don't worry if one node seems to be completing tasks within the script faster than the other node.

## The code is ugly. What gives?
I know.  This is a first run and it still needs come cleanup.