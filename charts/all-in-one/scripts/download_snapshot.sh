#!/usr/bin/env bash

cd /data

until apt-get -y update
do
  echo "Try again"
done

until apt-get -y install curl jq wget aria2 sudo zip
do
  echo "Try again"
done

base_url=${1:-https://snapshots.nine-chronicles.com/{{ $.Values.snapshot.path }}}
save_dir=${2:-"9c-main-snapshot_$(date +%Y%m%d_%H)"}
download_option=$3
service_name=$4
SLACK_WEBHOOK=$5
rollback_snapshot=${6:-"false"}
complete_snapshot_reset=${7:-"false"}
mainnet_snapshot_json_filename={{- if eq $.Values.global.networkType "Main" }}"latest.json"{{- else }}"mainnet_latest.json"{{- end }}

function download_with_retry() {
  local url=$1
  local save_dir=$2
  local output_file=$3

  while true; do
    echo "Downloading $url"

    aria2c "$url" -d "$2" -o "$3" -j5 -x5 --continue=true
    if [ ! -f "$save_dir/$output_file.aria2" ] && [ -f "$save_dir/$output_file" ]; then
        echo "Download successful: $save_dir/$output_file"
        return 0
    fi

    echo "Download failed (.aria2 file detected). Retrying in 10 seconds..."
    rm -f "$save_dir/$output_file" "$save_dir/$output_file.aria2"
    sleep 10
  done
}


if [ $download_option = "true" ]
then
  echo "Start download snapshot"
  if [ $service_name != "snapshot" ]
  then
    echo $service_name
  fi

  # strip tailing slash
  base_url=${base_url%/}

  function get_snapshot_value() {
      snapshot_json_url="$1"
      snapshot_param="$2"

      snapshot_param_return_value=$(curl --silent "$snapshot_json_url" | jq ".$snapshot_param")
      echo "$snapshot_param_return_value"
  }

  function download_unzip_partial_snapshot() {
    snapshot_json_filename="latest.json"
    snapshot_zip_filename="state_latest.zip"
    snapshot_zip_filename_array=("$snapshot_zip_filename")
    mainnet_snapshot_json_url="$base_url/$mainnet_snapshot_json_filename"
    mainnet_snapshot_blockIndex=$(get_snapshot_value "$mainnet_snapshot_json_url" "Index")
    mainnet_snapshot_blockEpoch=$(get_snapshot_value "$mainnet_snapshot_json_url" "BlockEpoch")

    if [ "$mainnet_snapshot_blockEpoch" -le $1 ]; then
        if [ $rollback_snapshot = "false" ]; then
          if [ "$mainnet_snapshot_blockIndex" -le $2 ]; then
              echo "Skip snapshot download because the local chain tip is greater than the snapshot tip."
              return
          fi
        fi
    fi

    while :
    do
        snapshot_json_url="$base_url/$snapshot_json_filename"
        BlockEpoch=$(get_snapshot_value "$snapshot_json_url" "BlockEpoch")
        TxEpoch=$(get_snapshot_value "$snapshot_json_url" "TxEpoch")
        PreviousBlockEpoch=$(get_snapshot_value "$snapshot_json_url" "PreviousBlockEpoch")
        PreviousTxEpoch=$(get_snapshot_value "$snapshot_json_url" "PreviousTxEpoch")

        snapshot_zip_filename="snapshot-$BlockEpoch-$TxEpoch.zip"
        snapshot_zip_filename_array+=("$snapshot_zip_filename")
        rm -r $save_dir/block/epoch$BlockEpoch/*
        rm -r $save_dir/tx/epoch$BlockEpoch/*

        if [ $(("$PreviousBlockEpoch"+2)) -lt $1 ]
        then
            break
        fi

        snapshot_json_filename="snapshot-$PreviousBlockEpoch-$PreviousTxEpoch.json"
    done

    if [[ ! -d "$save_dir" ]]
    then
        echo "[Info] The directory $save_dir does not exist and is created."
        mkdir -p "$save_dir"
    fi

    rm -r $save_dir/block/blockindex/*
    rm -r $save_dir/tx/txindex/*
    rm -r $save_dir/txbindex/*
    rm -r $save_dir/blockcommit/*
    rm -r $save_dir/txexec/*
    rm -r $save_dir/states/*

    for ((i=${#snapshot_zip_filename_array[@]}-1; i>=0; i--))
    do
        snapshot_zip_filename="${snapshot_zip_filename_array[$i]}"
        rm "$snapshot_zip_filename" 2>/dev/null

        snapshot_zip_url="$base_url/$snapshot_zip_filename"
        echo "$snapshot_zip_url"

        #aria2c "$snapshot_zip_url" -d "$save_dir" -j10 -x10 --continue=true
        download_with_retry "$snapshot_zip_url" "$save_dir" "$snapshot_zip_filename"
        echo "Unzipping $snapshot_zip_filename"
        unzip -o "$save_dir/$snapshot_zip_filename" -d "$save_dir"
        rm "$save_dir/$snapshot_zip_filename"
    done

    if [ -f $save_dir/$mainnet_snapshot_json_filename ]; then
      rm $save_dir/$mainnet_snapshot_json_filename
    fi

    # aria2c "$base_url/$mainnet_snapshot_json_filename" -d "$save_dir" -o "$mainnet_snapshot_json_filename" -j10 -x10 --continue=true
    download_with_retry "$base_url/$mainnet_snapshot_json_filename" "$save_dir" "$mainnet_snapshot_json_filename"
  }

  function download_unzip_full_snapshot() {
      snapshot_json_filename="latest.json"
      snapshot_zip_filename="state_latest.zip"
      snapshot_zip_filename_array=("$snapshot_zip_filename")

      while :
      do
          snapshot_json_url="$base_url/$snapshot_json_filename"
          echo "$snapshot_json_url"

          BlockEpoch=$(get_snapshot_value "$snapshot_json_url" "BlockEpoch")
          TxEpoch=$(get_snapshot_value "$snapshot_json_url" "TxEpoch")
          PreviousBlockEpoch=$(get_snapshot_value "$snapshot_json_url" "PreviousBlockEpoch")
          PreviousTxEpoch=$(get_snapshot_value "$snapshot_json_url" "PreviousTxEpoch")

          snapshot_zip_filename="snapshot-$BlockEpoch-$TxEpoch.zip"
          snapshot_zip_filename_array+=("$snapshot_zip_filename")

          if [ "$PreviousBlockEpoch" -eq 0 ]
          then
              break
          fi

          snapshot_json_filename="snapshot-$PreviousBlockEpoch-$PreviousTxEpoch.json"
      done

      if [[ ! -d "$save_dir" ]]
      then
          echo "[Info] The directory $save_dir does not exist and is created."
          mkdir -p "$save_dir"
      fi

      for ((i=${#snapshot_zip_filename_array[@]}-1; i>=0; i--))
      do
          snapshot_zip_filename="${snapshot_zip_filename_array[$i]}"
          rm "$snapshot_zip_filename" 2>/dev/null

          snapshot_zip_url="$base_url/$snapshot_zip_filename"
          echo "$snapshot_zip_url"

          #aria2c "$snapshot_zip_url" -j10 -x10 --continue=true
          download_with_retry "$snapshot_zip_url" "$save_dir" "$snapshot_zip_filename"
          echo "Unzipping $snapshot_zip_filename"
          unzip -o "$save_dir/$snapshot_zip_filename" -d "$save_dir"
          rm "$save_dir/$snapshot_zip_filename"
      done

      #aria2c "$base_url/$mainnet_snapshot_json_filename" -d "$save_dir" -o "$mainnet_snapshot_json_filename" -j10 -x10 --continue=true
      download_with_retry "$base_url/$mainnet_snapshot_json_filename" "$save_dir" "$mainnet_snapshot_json_filename"
  }

  if [ -f $save_dir/$mainnet_snapshot_json_filename ]
  then
    if [ $complete_snapshot_reset = "true" ]
    then
      echo "Completely delete the existing store and download a new snapshot"
      rm -r "$save_dir"
      mkdir -p "$save_dir"
      download_unzip_full_snapshot
    else
      local_chain_tip_index="$((/app/NineChronicles.Headless.Executable chain tip "RocksDb" "$save_dir") | jq -r '.Index')"
      if [ -f $save_dir/$mainnet_snapshot_json_filename ]
      then
        local_previous_mainnet_blockEpoch=$(cat "$save_dir/$mainnet_snapshot_json_filename" | jq ".BlockEpoch")
        download_unzip_partial_snapshot $local_previous_mainnet_blockEpoch $local_chain_tip_index
      else
        local_chain_tip_timestamp="$((/app/NineChronicles.Headless.Executable chain tip "RocksDb" "$save_dir") | jq -r '.Timestamp')"
        epoch_seconds=$(date -d "$local_chain_tip_timestamp" +%s)
        echo $epoch_seconds
        local_chain_tip_blockEpoch=$(($epoch_seconds / 86400))
        echo $local_chain_tip_blockEpoch
        download_unzip_partial_snapshot $local_chain_tip_blockEpoch $local_chain_tip_index
      fi
    fi
  else
    download_unzip_full_snapshot
  fi

  # The return value for the program that calls this script
  echo "$save_dir"
  if [ $service_name != "snapshot" ]
  then
    echo $service_name
  fi
else
  echo "Skip download snapshot"
  if [ $service_name != "snapshot" ]
  then
    echo $service_name
  fi
fi
