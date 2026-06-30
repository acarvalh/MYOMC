ALL_TOOLS      += celeritas
celeritas_EX_INCLUDE := /cvmfs/cms.cern.ch/el8_amd64_gcc12/external/celeritas/v0.4.1-71d49a779b210a2204700c977d232388/include
celeritas_EX_LIB := accel celeritas corecel
celeritas_EX_USE := geant4core expat xerces-c vecgeom_interface vecgeom
celeritas_EX_FLAGS_REM_CXXFLAGS  := -Werror=missing-braces

