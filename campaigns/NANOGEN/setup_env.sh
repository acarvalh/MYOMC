#!/bin/bash
#export SYSTEM_RELEASE=`cat /etc/redhat-release`
#if { [[ $SYSTEM_RELEASE == *"release 7"* ]]; }; then
#  echo "Running setup_env.sh on SLC6."
#  if { [[ $(hostname -s) = lxplus* ]]; }; then
#  	ssh -Y lxplus6 "cd $PWD; source setup_env.sh;"
#  elif { [[ $(hostname -s) = cmslpc* ]]; }; then
#    #ssh -Y cmslpc-sl6 "cd $PWD; source setup_env.sh;"
#    ssh -Y cmslpc23 "cd $PWD; source setup_env.sh;"
#  else
#  	echo "Not on cmslpc or lxplus, not sure what to do."
#  	return 1
#  fi
#  return 1
#fi

if [ -d env ]; then
	rm -rf env
fi

mkdir -pv env
cd env
source /cvmfs/cms.cern.ch/cmsset_default.sh

# el9-native Run 3 release (see run.sh) so the el9 gridpack runs natively.
export SCRAM_ARCH=el9_amd64_gcc12
scram project -n "CMSSW_14_1_8" CMSSW_14_1_8
cd CMSSW_14_1_8/src
eval `scram runtime -sh`
scram b
cd ../../

tar -czf env.tar.gz ./CMSSW*
mv env.tar.gz ..
cd ..

