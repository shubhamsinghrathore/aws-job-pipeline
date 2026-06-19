#!/bin/bash


for param in "$@"

do 
    if [[ ! "$param" =~ [dD1] ]]; then
        echo "$param"
    fi
done


