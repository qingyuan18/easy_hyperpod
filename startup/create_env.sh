#!/usr/bin/env bash
set -ex

wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
chmod +x Miniconda3-latest-Linux-x86_64.sh
./Miniconda3-latest-Linux-x86_64.sh -b -f -p ./miniconda3

source ./miniconda3/bin/activate

conda create -y -n pt_fsdp python=3.10

source activate pt_fsdp

# Install PyTorch
pip install torch torchvision torchaudio
pip install packaging transformers accelerate ninja tensorboard h5py datasets
pip uninstall -y deepspeed && pip3 install deepspeed
pip install transformers==4.28.0
pip install lightning
apt install jq

# create output dir
mkdir tensorboard
mkdir checkpoints