#!/bin/bash
if [ ! -d deps/pjsip ]; then
    tar zxvf deps/pjsip-2.10.tgz -C deps/
fi
