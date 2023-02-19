#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

set -eu

if [[ $# -lt 1 ]] ; then
    echo "./deploy_skyhook.sh [nodes] [branch] [deploy CLS libs] [build python] [build java] [nproc]"
    exit 1
fi

NODES=$1
BRANCH=${2:-master}
DEPLOY_CLS_LIBS=${3:-true}
BUILD_PYTHON_BINDINGS=${4:-false}
BUILD_JAVA_BINDINGS=${5:-false}
NPROC=${6:-4}

IFS=',' read -ra NODE_LIST <<< "$NODES"; unset IFS

apt update 
apt install -y python3 \
               python3-pip \
               python3-venv \
               python3-numpy \
               cmake \
               libradospp-dev \
               rados-objclass-dev \
               llvm \
               default-jdk \
               maven
echo "-----------------------------install common package---------------------------------------"


if [ ! -d "/home/yue21/skyhookdm/scripts/deploy/arrow" ]; then
  git clone https://github.com/apache/arrow /home/yue21/skyhookdm/scripts/deploy/arrow
  cd /home/yue21/skyhookdm/scripts/deploy/arrow
  git submodule update --init --recursive
fi
echo "-----------------------------clone skyhook code to /home/yue21/skyhookdm/scripts/deploy/arrow---------------------------------------"


cd /home/yue21/skyhookdm/scripts/deploy/arrow
git fetch origin $BRANCH
git pull
git checkout $BRANCH
mkdir -p cpp/release
cd cpp/release
echo "-----------------------------check out skyhook master branch---------------------------------------"


#  configure the build files for Apache Arrow using CMake
cmake -DARROW_SKYHOOK=ON \
  -DARROW_PARQUET=ON \
  -DARROW_WITH_SNAPPY=ON \
  -DARROW_WITH_ZLIB=ON \
  -DARROW_BUILD_EXAMPLES=ON \
  -DPARQUET_BUILD_EXAMPLES=ON \
  -DARROW_PYTHON=ON \
  -DARROW_ORC=ON \
  -DARROW_JAVA=ON \
  -DARROW_JNI=ON \
  -DARROW_DATASET=ON \
  -DARROW_CSV=ON \
  -DARROW_WITH_LZ4=ON \
  -DARROW_WITH_ZSTD=ON \
  ..

trap 'echo "Interrupt signal received, exiting script"; exit' INT
read -p "Press [Enter] to exit the script"

make -j${NPROC} install #compiles the Apache Arrow code using 4 parallel jobs
echo "-----------------------------Build Arrow---------------------------------------"
trap 'echo "Interrupt signal received, exiting script"; exit' INT
read -p "Press [Enter] to exit the script"

if [[ "${BUILD_PYTHON_BINDINGS}" == "true" ]]; then
  export WORKDIR=${WORKDIR:-$HOME}
  export ARROW_HOME=$WORKDIR/dist
  export PYARROW_WITH_DATASET=1
  export PYARROW_WITH_PARQUET=1
  export PYARROW_WITH_SKYHOOK=1

  mkdir -p /root/dist/lib
  mkdir -p /root/dist/include

  cp -r /usr/local/lib/. /root/dist/lib
  cp -r /usr/local/include/. /root/dist/include

  cd /home/yue21/skyhookdm/scripts/deploy/arrow/python
  pip3 install -r requirements-build.txt -r requirements-test.txt
  pip3 install wheel
  rm -rf dist/*
  python3 setup.py build_ext --inplace --bundle-arrow-cpp bdist_wheel
  pip3 install --upgrade dist/*.whl

  echo "-----------------------------Build Python Bindings---------------------------------------"
fi

if [[ "${DEPLOY_CLS_LIBS}" == "true" ]]; then
  cd /home/yue21/skyhookdm/scripts/deploy/arrow/cpp/release/release
  for node in ${NODE_LIST[@]}; do
    scp libcls* $node:/usr/lib/rados-classes/
    scp libarrow* $node:/usr/lib/
    scp libparquet* $node:/usr/lib/
    #ssh $node systemctl restart ceph-osd.target
  done

  echo "-----------------------------Deploy Cls Libs---------------------------------------"
  trap 'echo "Interrupt signal received, exiting script"; exit' INT
  read -p "Press [Enter] to exit the script"
fi

if [[ "${BUILD_JAVA_BINDINGS}" == "true" ]]; then
    mkdir -p /home/yue21/skyhookdm/scripts/deploy/arrow/java/dist
    cp -r /home/yue21/skyhookdm/scripts/deploy/arrow/cpp/release/release/libarrow_dataset_jni.so* /home/yue21/skyhookdm/scripts/deploy/arrow/java/dist

    mvn="mvn -B -DskipTests -Dcheckstyle.skip -Drat.skip=true -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn"
    mvn="${mvn} -T 2C"
    cd /home/yue21/skyhookdm/scripts/deploy/arrow/java
    ${mvn} clean install package -P arrow-jni -pl dataset,format,memory,vector -am -Darrow.cpp.build.dir=/home/yue21/skyhookdm/scripts/deploy/arrow/cpp/release/release

    echo "-----------------------------Build Java Bingings---------------------------------------"
fi

export LD_LIBRARY_PATH=/usr/local/lib
sudo cp /usr/local/lib/libparq* /usr/lib/

echo "successful"
