#!/bin/bash
 
PWD=`pwd`
OUT=/path/to/dir/`date '+%Y%m%d%H%M%S'`_`basename ${PWD}`.tar
echo "tar backup start."
echo "--> ${PWD}"
 
tar cf ${OUT} ./
 
echo "done."
echo "--> ${OUT}"