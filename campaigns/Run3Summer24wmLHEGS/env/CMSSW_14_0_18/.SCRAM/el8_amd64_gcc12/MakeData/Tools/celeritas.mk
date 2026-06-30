ALL_TOOLS      += celeritas
celeritas_EX_INCLUDE := /cvmfs/cms.cern.ch/el8_amd64_gcc12/external/celeritas/v0.4.1-d335eec66382f32976d57d900078a1e1/include
celeritas_EX_LIB := accel celeritas corecel
celeritas_EX_USE := vecgeom_interface geant4core vecgeom
celeritas_EX_FLAGS_REM_CXXFLAGS  := -Werror=missing-braces

