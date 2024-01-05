#!/bin/bash

# The first argument is the number of commits to process
branch=$1
num_commits=$2

# Initialize an associative array to hold the files to check
declare -A files_to_check

# Populate the array with the script arguments, starting from the second argument
for file in "${@:3}"
do
  files_to_check["$file"]=1
done

# Get a list of all commit hashes, in reverse order
all_commits=$(git log origin/$branch --no-merges --format=%H --reverse -n $num_commits)

# Initialize an associative array to store the test files
declare -A test_files
declare -A uncorrelated_test_files

# Initialize an array to store the files changed in the previous commit
prev_changed_files=()

# For each commit...
for commit in $all_commits
do
  # Get a list of all files that were changed in the current commit
  files=$(git diff-tree --no-commit-id --name-only -r $commit)

  declare -A correlated_test_files

  # # For each file in the list of files changed in the previous commit...
  for file in "${prev_changed_files[@]}"
  do
    # If the file is in the list of files to check...
    if [[ ${files_to_check[$file]} ]]; then
      # For each file...
      for test_file in $files
      do
        # If the file is in the test/ directory and ends with _test.rb...
        if [[ $test_file == spec/*_spec.rb ]]
        then
          # Increment the count in the associative array
          test_files["$file|$test_file"]=$((test_files["$file|$test_file"]+1))
          # Add the test file to the correlated_test_files array
          correlated_test_files["$test_file"]=1
        fi
      done
    fi
  done

  # For each file in the list of files changed in the current commit...
  for file in $files
  do
    # If the file is in the list of files to check...
    if [[ ${files_to_check[$file]} ]]; then
      # For each file...
      for test_file in $files
      do
        # If the file is in the test/ directory and ends with _test.rb...
        if [[ $test_file == spec/*_spec.rb ]]
        then
          # Increment the count in the associative array
          test_files["$file|$test_file"]=$((test_files["$file|$test_file"]+1))
          # Add the test file to the correlated_test_files array
          correlated_test_files["$test_file"]=1
        fi
      done
    fi
  done

  # For each file...
  for test_file in $files
  do
    # If the file is in the test/ directory and ends with _test.rb...
    if [[ $test_file == spec/*_spec.rb ]]
    then
      # If the test file is not correlated to any of the files to check in the current commit...
      if [[ -z ${correlated_test_files[$test_file]} ]]
      then
        # Increment the count in the associative array
        uncorrelated_test_files["$test_file"]=$((uncorrelated_test_files["$test_file"]+1))
      fi
    fi
  done

  # Clear the correlated_test_files array for the next commit
  unset correlated_test_files

  # Store the list of files changed in this commit for the next iteration
  prev_changed_files=($files)
done

# OUTPUT

# Initialize an associative array to hold the JSON strings for each file
declare -A file_jsons

# Add the test_files to the file_jsons associative array
for key in "${!test_files[@]}"
do
  file=${key%|*}
  test_file=${key#*|}
  count=${test_files[$key]}
  # Append to the JSON string for this file
  file_jsons["$file"]+="\"$test_file\": $count,"
done

# Initialize an empty string for the test_files JSON
correlated_files_json=""

# Add the file_jsons to the correlated_files_json string
for file in "${!file_jsons[@]}"
do
  # Remove the trailing comma from the JSON string for this file
  file_json=${file_jsons[$file]%?}
  # Append to the correlated_files_json string
  correlated_files_json+="\"$file\": { $file_json },"
done

# Remove the trailing comma from the correlated_files_json string
correlated_files_json=${correlated_files_json%?}

# Initialize an empty string for the uncorrelated_test_files JSON
uncorrelated_files_json=""

# Add the uncorrelated_test_files to the uncorrelated_files_json string
for key in "${!uncorrelated_test_files[@]}"
do
  count=${uncorrelated_test_files[$key]}
  # Append to the uncorrelated_files_json string
  uncorrelated_files_json+="\"$key\": $count,"
done

# Remove the trailing comma from the uncorrelated_files_json string
uncorrelated_files_json=${uncorrelated_files_json%?}

# Output the JSON
echo "{ \"correlated_files\": { $correlated_files_json }, \"uncorrelated_files\": { $uncorrelated_files_json } }"