#!/bin/bash
# ---------------------------------------------------------------------------------------
# Title: EC2 User Data Script
# Date: 2025-04-25
# Version: 1.0
# Written By: Carrick Bradley
# Tested on: Ubuntu 22.04 LTS (Jammy Jellyfish) & Ubuntu 24.04 (Noble Numbat)
# ---------------------------------------------------------------------------------------
# Description: This script performs the following tasks:
# - Logs the start of the script
# - Checks if the script is already running
# - Creates a PID file to prevent multiple instances of the script from running
# - Validates global variables
# - Creates an EFS mount point
# - Mounts the EFS filesystem
# - Cleans up the PID file on exit
# - Logs the completion of the script
# ---------------------------------------------------------------------------------------
# Usage: ./user-data-0.sh [log_file_path]
#
# Requirements: This script requires root privileges to run and will run on
#               Ubuntu 22.04 LTS (Jammy Jellyfish) & Ubuntu 24.04 (Noble Numbat)
#               and other Debian-based systems.
# ---------------------------------------------------------------------------------------

# Exit on error, uninitialized variable, or failed command in a pipeline
set -euo pipefail

# Set the frontend to noninteractive when installing packages
export DEBIAN_FRONTEND=noninteractive

# Define exit codes
SUCCESS=0
ERROR=1
WARNING=2

# Define global variables
LOGFILE="${1:-/var/log/startup-script-$(date '+%Y%m%d_%H%M%S').log}"
PIDFILE="/var/run/startup-script.pid"
TOKEN=$(curl -X PUT -s -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" http://169.254.169.254/latest/api/token)
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
BUCKET_NAME=$(aws ssm get-parameter --name "/AcmeLabs/Blog/Ami/S3/Bucket/Name" --query "Parameter.Value" --output text)
EFS_FS_ID=$(aws ssm get-parameter --name "/AcmeLabs/Blog/Efs/Id" --query "Parameter.Value" --output text)

# Function to log messages with a default log level of INFO
capture() {
    # Define local variables for this function
    local MESSAGE="$1"
    local LEVEL="${2:-INFO}"
    local TIMESTAMP

    # Define timestamp variable with the current date and time
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Log the message to the log file & print it to the console
    # -a flag to append the message to the log file
    echo "$TIMESTAMP - [$LEVEL] - $MESSAGE" | tee -a "$LOGFILE"

    # Log the message to syslog
    # -t flag to specify the tag for the syslog message
    logger -t aws-cli "$MESSAGE"
}

# Function to start logging
get_logging() {
    capture "Starting logging to '$LOGFILE'..."
    
    # Check if the log file exists, if not create it
    capture "Checking if log file '$LOGFILE' exists..."
    if [ ! -f "$LOGFILE" ]; then
        capture "Log file '$LOGFILE' does not exist. Creating it..."
        # Create the log file
        touch "$LOGFILE"
        capture "Log file '$LOGFILE' created."
    else
        # Log a message if the log file already exists and append to it
        capture "Log file '$LOGFILE' already exists...appending to it." "WARNING"
    fi

    # Redirect all output to the log file
    # -a flag to append the output to the log file
    # 2>&1 redirects stderr to stdout
    exec > >(tee -a "$LOGFILE") 2>&1
    capture "Logging started."

    capture "Starting the startup-script..."
}

# Function to validate string is not an empty string
# Passing custom error, success and hidden as arguments
# Hidden is used to hide the string in the log e.g. passwords (sensitive data)
validate_string() {
    local STRING="$1"
    local ERROR_MESSAGE="$2"
    local SUCCESS_MESSAGE="$3"
    local HIDDEN_STRING="$4"

    capture "Validating string is not empty..."
    
    # Validate string is not an empty string
    if [ -z "$STRING" ]; then
        # Log an error if the string is empty
        capture "$ERROR_MESSAGE" "ERROR"
        exit $ERROR
    fi

    # Validate HIDDEN_STRING is set to "hide" or "show"
    if [ "$HIDDEN_STRING" == "hide" ]; then
        # Log a success message with the string hidden
        capture "$SUCCESS_MESSAGE"
    elif [ "$HIDDEN_STRING" == "show" ]; then
        # Log a success message with the string visible
        capture "$SUCCESS_MESSAGE: $STRING"
    else
        # Log an error if HIDDEN_STRING is not valid
        capture "Invalid option for HIDDEN_STRING. Use 'hide' or 'show'." "ERROR"
        exit $ERROR
    fi
}

# Validate log file global variable is not an empty string
validate_string "$LOGFILE" "Failed to validate log file." "Log file validated successfully." show

# Validate PID file global variable is not an empty string
validate_string "$PIDFILE" "Failed to validate PID file." "PID file validated successfully." show

# Validate IMDSv2 token global variable is not an empty string
validate_string "$TOKEN" "Failed to validate IMDSv2 token." "IMDSv2 token validated successfully." show

# Validate instance id global variable is not an empty string
validate_string "$INSTANCE_ID" "Failed to validate instance id." "Instance id validated successfully." show

# Validate S3 bucket name global variable is not an empty string
validate_string "$BUCKET_NAME" "Failed to validate S3 bucket name." "S3 bucket name validated successfully." show

# Validate EFS filesystem id global variable is not an empty string
validate_string "$EFS_FS_ID" "Failed to validate EFS filesystem id." "EFS filesystem id validated successfully." show

# Function to validate if prior command was successful
# Passing custom error & success messages as arguments
validate_command() {
    local ERROR_MESSAGE="$1"
    local SUCCESS_MESSAGE="$2"
    local OVERWRITE_ERROR="$3"

    # Capture the exit status of the last command
    local EXIT_STATUS=$?

    if [ $EXIT_STATUS -ne 0 ]; then
        # Command failed
        if [ "$OVERWRITE_ERROR" == "disable" ]; then
            # Log an error and exit if the command failed and overwrite is disabled
            capture "$ERROR_MESSAGE" "ERROR"
            exit $ERROR
        else
            # Log the error but do not exit if overwrite is enabled
            capture "$ERROR_MESSAGE" "WARNING"
        fi
    else
        # Log a success message if the command succeeded
        capture "$SUCCESS_MESSAGE"
    fi
}

# Function to check if the script is already running
get_running() {
    capture "Checking if user data script is already running..."

    # Check if the pid file exists
    if [ -f "$PIDFILE" ]; then
        # Log a message and exit if the pid file exists
        capture "User data script is already running."
        exit $SUCCESS
    else
        # Create a PID file if it doesn't exist by calling create_pid function
        capture "User data script is not running. Creating PID file..."
        create_pid
    fi
}

# Function to create a PID file
create_pid() {
    capture "Creating PID file..."

    # Create a PID file with the current process ID
    echo $$ > "$PIDFILE"

    validate_command "Failed to create PID file." "PID file created successfully." disable
    capture "PID file created with process ID: $(cat $PIDFILE)"
    trap 'rm -f "$PIDFILE"' EXIT
}

# Function to clean up the files on exit
cleanup() {
    capture "Deleting pid file..."

    # Delete the PID file
    # -f flag to force the removal of the file
    rm -f "$PIDFILE"

    # Check if the prior command was successful
    validate_command "Failed to delete PID file." "PID file deleted successfully." disable
}
trap cleanup EXIT

# Function to stop Apache2 service
stop_apache() {
    capture "Stopping Apache2 service..."
    
    # Stop the Apache2 service
    if systemctl stop apache2; then
        capture "Apache2 service stopped successfully."
    else
        # Log an error if the Apache2 service stop fails
        capture "Failed to stop Apache2 service." "ERROR"
        exit $ERROR
    fi
}

# Function to start Apache2 service
start_apache() {
    capture "Starting Apache2 service..."
    
    # Start the Apache2 service
    if systemctl start apache2; then
        capture "Apache2 service started successfully."
    else
        # Log an error if the Apache2 service start fails
        capture "Failed to start Apache2 service." "ERROR"
        exit $ERROR
    fi
}

# Function to cleanup log files
cleanup_logs() {
    capture "Cleaning up log files..."

    # Delete the log file
    # -f flag to force the removal of the file
    rm -f "$LOGFILE"

    # Check if the prior command was successful
    validate_command "Failed to delete log file." "Log file deleted successfully." disable

    # Delete startup script log file
    # -f flag to force the removal of the file
    rm -f /var/log/startup-script*

    # Check if the prior command was successful
    validate_command "Failed to delete startup script log file." "Startup script log file deleted successfully." disable
}

# Function to create & mount an EFS filesystem
congifure_efs() {
    capture "Creating EFS mount point..."

    # Stop Apache2 service before creating the EFS mount point
    stop_apache

    if mkdir -p /var/www/html; then
        capture "EFS mount point created successfully."

        # Adding EFS entry to /etc/fstab
        capture "Adding EFS entry to /etc/fstab..."
        if echo "$EFS_FS_ID.efs.us-east-1.amazonaws.com:/ /var/www/html nfs4 defaults,_netdev 0 0" >> /etc/fstab; then
            capture "EFS entry added to /etc/fstab successfully."

            # Reload systemd configuration
            capture "Reloading systemd configuration..."
            if systemctl daemon-reload; then
                capture "Systemd configuration reloaded successfully."

                # Mounting EFS
                capture "Mounting EFS to /var/www/html..."
                if mount -a; then
                    capture "EFS mounted successfully."
                    # Start Apache2 service after mounting EFS
                    start_apache
                else
                    # Log an error if the EFS mount fails
                    capture "Failed to mount EFS." "ERROR"
                    exit $ERROR
                fi
            else
                # Log an error if the systemd configuration reload fails
                capture "Failed to reload systemd configuration." "ERROR"
                exit $ERROR
            fi
        else
            # Log an error if the EFS entry addition fails
            capture "Failed to add EFS to /etc/fstab." "ERROR"
            exit $ERROR
        fi
    else
        # Log an error if the EFS mount point creation fails
        capture "Failed to create EFS mount point." "ERROR"
        exit $ERROR
    fi
}

# Main execution
get_logging
get_running
cleanup_logs
congifure_efs

# Log the completion of our script
capture "Startup script completed successfully!"
exit $SUCCESS
