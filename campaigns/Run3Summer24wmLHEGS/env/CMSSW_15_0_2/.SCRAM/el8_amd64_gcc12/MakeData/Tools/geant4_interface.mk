ALL_TOOLS      += geant4_interface
geant4_interface_EX_INCLUDE := /cvmfs/cms.cern.ch/el8_amd64_gcc12/external/geant4/11.2.2-2874e23607698d953f66cc1f6e4baad9/include/Geant4 /cvmfs/cms.cern.ch/el8_amd64_gcc12/external/geant4/11.2.2-2874e23607698d953f66cc1f6e4baad9/include
geant4_interface_EX_USE := clhep vecgeom zlib expat xerces-c root_cxxdefaults
geant4_interface_EX_FLAGS_CPPDEFINES  := -DGNU_GCC -DG4V9
geant4_interface_EX_FLAGS_CXXFLAGS  := -ftls-model=global-dynamic -pthread

