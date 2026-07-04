#!/bin/bash
env python3 -V|grep -E "3.11|3.10|3.9" > /dev/null

RESULT=$?
if [ $RESULT -ne 0 ]; then
    echo
    echo "Please install Python 3.9, 3.10 or 3.11 from https://www.python.org/"
    echo
    exit 1
fi

which port > /dev/null
RESULT=$?

if [ $RESULT -ne 0 ]; then
    echo
    echo "Please install Mac Ports from https://www.macports.org"
    echo
    exit 1
fi

pip3 install --user virtualenv

