#!/bin/bash --login
#SBATCH --time=2:00:00
#SBATCH --gpus-per-node=2
#SBATCH --tasks-per-node=2
#SBATCH --gpus-per-task=1
#SBATCH --cpus-per-gpu=6
#SBATCH --mem-per-gpu=45G
##SBATCH --constraint=v100
##SBATCH --constraint=cpu_intel_platinum_8260
#SBATCH --partition=batch
#SBATCH --output=../results/%x/slurm-%j.out
#SBATCH --error=../results/%x/slurm-%j.err

# Stops execution of script if any step return non-zero exit code
set -e

# Need to define persistent storage for logging... 
PERSISTENT_LOGGING_DIR=../results/$SLURM_JOB_NAME/logs
PERSISTENT_CHECKPOINTS_DIR=$PERSISTENT_LOGGING_DIR/checkpoints
PERSISTENT_TENSORBOARD_DIR=$PERSISTENT_LOGGING_DIR/tensorboard

# N.B. mkdir does not overwrite if these directories already exist
mkdir -p $PERSISTENT_CHECKPOINTS_DIR
mkdir -p $PERSISTENT_TENSORBOARD_DIR

# ...but for best performance write checkpoints and tensorboard logs to local storage
LOCAL_LOGGING_DIR=/tmp/$SLURM_JOB_NAME/$SLURM_JOB_ID/logs
LOCAL_CHECKPOINTS_DIR=$LOCAL_LOGGING_DIR/checkpoints
LOCAL_TENSORBOARD_DIR=$LOCAL_LOGGING_DIR/tensorboard
mkdir -p $LOCAL_CHECKPOINTS_DIR
mkdir -p $LOCAL_TENSORBOARD_DIR

# Load software stack
module purge
module load cuda/10.1.243
conda activate ../env

# Start the nvdashboard server running in the background
NVDASHBOARD_PORT=8000
python -m jupyterlab_nvdashboard.server $NVDASHBOARD_PORT &
NVDASHBOARD_PID=$!

# Start the TensorBoard server running in the background
TENSORBOARD_PORT=0
tensorboard --logdir $LOCAL_TENSORBOARD_DIR --port $TENSORBOARD_PORT --bind_all &
TENSORBOARD_PID=$!

# start the training process in the background
export NCCL_DEBUG=INFO
horovodrun -np $SLURM_NTASKS python $TRAINING_SCRIPT \
    --data-dir $DATA_DIR \
    --read-checkpoints-from $PERSISTENT_CHECKPOINTS_DIR \
    --write-checkpoints-to  $LOCAL_CHECKPOINTS_DIR \
    --tensorboard-logging-dir $LOCAL_TENSORBOARD_DIR \
    --batch-size 64 &
HOROVODRUN_PID=$!

# asynchronous rsync of training logs between local and persistent storage
RSYNC_DELAY_SECONDS=600
HOROVODRUN_STATE=$(ps -h --pid $HOROVODRUN_PID -o state | head -n 1)
while [ "${HOROVODRUN_STATE}" != "" ]
    do
        rsync -a $LOCAL_CHECKPOINTS_DIR/ $PERSISTENT_CHECKPOINTS_DIR
        rsync -a $LOCAL_TENSORBOARD_DIR/ $PERSISTENT_TENSORBOARD_DIR
        sleep $RSYNC_DELAY_SECONDS
        HOROVODRUN_STATE=$(ps -h --pid $HOROVODRUN_PID -o state | head -n 1)
done

# kill off the monitoring processes
kill $NVDASHBOARD_PID $TENSORBOARD_PID

# make sure to get any new files written since last rsync 
rsync -a $LOCAL_CHECKPOINTS_DIR/ $PERSISTENT_CHECKPOINTS_DIR
rsync -a $LOCAL_TENSORBOARD_DIR/ $PERSISTENT_TENSORBOARD_DIR
