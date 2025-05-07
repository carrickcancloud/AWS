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
# - Updates and upgrades the operating system
# - Installs required packages
# - Creates an EFS mount point
# - Mounts the EFS filesystem
# - Configures Apache web server
# - Downloads and extracts Joomla CMS
# - Configures Joomla CMS
# - Cleans up temporary files
# - Terminates the EC2 instance
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
BUCKET_NAME=$(aws ssm get-parameter --name "/AcmeLabs/Blog/Ami/S3/Bucket/Name" --query "Parameter.Value" --output text)
TOKEN=$(curl -X PUT -s -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" http://169.254.169.254/latest/api/token)
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
EFS_FS_ID=$(aws ssm get-parameter --name "/AcmeLabs/Blog/Efs/Id" --query "Parameter.Value" --output text)

# Define an array of prerequisites packages that will be installed
PACKAGES=(
    build-essential
    coreutils
    util-linux
    dateutils
    jq
    php
    libapache2-mod-php
    php-mysql
    php-xml
    php-gd
    php-zip
    php-intl
    unzip
    apache2
    mysql-client
    nfs-common
)

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

# Validate packages global variable is not an empty string
validate_string "$PACKAGES" "Failed to validate packages." "Packages validated successfully." show

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
    validate_command "Failed to delete pid file." "PID file deleted successfully." disable

    # Delete joomla archive
    # -f flag to force the removal of the file
    rm -f /tmp/joomla.tar.gz

    # Check if the prior command was successful
    validate_command "Failed to delete joomla archive." "Joomla archive deleted successfully." disable

    # Delete joomla directory
    # -f flag to force the removal of the directory
    rm -rf /tmp/joomla

    # Check if the prior command was successful
    validate_command "Failed to delete joomla directory." "Joomla directory deleted successfully." disable
}
trap cleanup EXIT

# Function to update & upgrade the operating system
get_os_updates_and_upgrade() {
    capture "Updating and upgrading the operating system..."

    # Update the package list
    # -y flag to automatically answer yes to prompts
    capture "Updating package list..."
    if ! apt-get update -y; then
        # Log an error if the update fails
        capture "Failed to update package list." "ERROR"
        exit $ERROR
    fi
    capture "Package list updated successfully."

    # Upgrade installed packages
    # -y flag to automatically answer yes to prompts
    capture "Upgrading installed packages..."
    if ! apt-get upgrade -y; then
        # Log an error if the upgrade fails
        capture "Failed to upgrade packages." "ERROR"
        exit $ERROR
    fi
    capture "Packages upgraded successfully."

    # Remove unnecessary packages that are no longer in use
    # -y flag to automatically answer yes to prompts
    capture "Removing unnecessary packages..."
    if ! apt-get autoremove -y; then
        # Log an error if the removal fails
        capture "Failed to remove unnecessary packages." "ERROR"
        exit $ERROR
    fi
    capture "Unnecessary packages removed successfully."

    # Clean up package files
    # -y flag to automatically answer yes to prompts
    capture "Cleaning up package files..."
    if ! apt-get autoclean -y; then
        # Log an error if the cleanup fails
        capture "Failed to clean up package files." "ERROR"
        exit $ERROR
    fi
    capture "Package files cleaned up successfully."

    capture "Operating system updated and upgraded successfully."
}

# Function to install packages
get_packages() {
    capture "Installing required packages..."
    # Loop through the list of packages and install each one at a time
    # -y flag to automatically answer yes to prompts
    for PACKAGE_NAME in "${PACKAGES[@]}"; do
        capture "Installing package: $PACKAGE_NAME..."
        if apt-get install -qq -y "$PACKAGE_NAME"; then
            capture "Package '$PACKAGE_NAME' installed successfully."
        else
            # Log an error if the package is not installed
            capture "Failed to install package '$PACKAGE_NAME'. Please check if the package name is correct and if it is available in the repositories." "ERROR"
            exit $ERROR
        fi
    done
}

# Function to create & mount an EFS filesystem
congifure_efs() {
    capture "Creating EFS mount point..."
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

# Function to configure Apache2
configure_apache_server() {
    capture "Configuring Apache web server..."

    # Delete default index.html file
    # -f flag to force the removal of the file
    capture "Deleting default index.html file..."
    if [ -f /var/www/html/index.html ]; then
        if ! rm -f /var/www/html/index.html; then
            # Log an error if the default index.html file is not removed
            capture "Failed to remove default index.html file." "ERROR"
            exit $ERROR
        fi
        capture "Default index.html file removed successfully."
    fi
    
    # Check if DirectoryIndex is set to index.php first
    # grep -q used to check if the pattern exists in the file
    capture "Checking DirectoryIndex setting..."
    if ! grep -q '^DirectoryIndex index\.php' /etc/apache2/mods-enabled/dir.conf; then
        # Log a message if the DirectoryIndex is already set to index.php first
        capture "DirectoryIndex is not set to index.php first." "WARNING"
        capture "Adjusting DirectoryIndex setting..."
        # String substitution to adjust Apache dir.conf index preference
        # -i flag to edit the file in place
        if ! sed -i 's|DirectoryIndex index\.html index\.cgi index\.pl index\.php index\.xhtml index\.htm|DirectoryIndex index.php index.html index.cgi index.pl index.xhtml index.htm|' /etc/apache2/mods-enabled/dir.conf; then
            # Log an error if the DirectoryIndex is not adjusted
            capture "Failed to adjust DirectoryIndex setting." "ERROR"
            exit $ERROR
        fi
        capture "DirectoryIndex setting adjusted successfully."
    else
        # Log a message if the DirectoryIndex is not set to index.php first
        capture "DirectoryIndex is set to index.php first."
    fi

    # Check if output_buffering is set to 4096
    # grep -q used to check if the pattern exists in the file
    capture "Checking output_buffering setting..."
    if ! grep -q '^output_buffering = 4096' /etc/php/8.3/apache2/php.ini; then
        # Log a message if the output_buffering setting is already set to 4096
        capture "output_buffering setting is not set to 4096." "WARNING"
        capture "Adjusting output_buffering setting..."
        # String substitution to adjust php.ini output_buffering setting
        # -i flag to edit the file in place
        if ! sed -i 's|^output_buffering =.*|output_buffering = 4096|' /etc/php/8.3/apache2/php.ini; then
            # Log an error if the output_buffering setting is not adjusted
            capture "Failed to adjust output_buffering setting." "ERROR"
            exit $ERROR
        fi
        capture "output_buffering setting adjusted successfully."
    else
        # Log a message if the output_buffering setting is not set to 4096
        capture "output_buffering setting is set to 4096."
    fi

    # Check if session.use_cookies is set to 1
    # grep -q used to check if the pattern exists in the file
    capture "Checking session.use_cookies setting..."
    if ! grep -q '^session.use_cookies = 1' /etc/php/8.3/apache2/php.ini; then
        # Log a message if the session.use_cookies setting is not set to 1
        capture "session.use_cookies setting is not set to 1." "WARNING"
        capture "Adjusting session.use_cookies to 1..."
        # String substitution to adjust php.ini session.use_cookies setting
        # -i flag to edit the file in place
        if ! sed -i 's|^session.use_cookies =.*|session.use_cookies = 1|' /etc/php/8.3/apache2/php.ini; then
            # Log an error if the session.use_cookies setting is not adjusted
            capture "Failed to adjust session.use_cookies setting." "ERROR"
            exit $ERROR
        fi
        capture "session.use_cookies setting adjusted successfully."
    else
        capture "session.use_cookies setting is already set to 1."
    fi

    # Check if session.use_only_cookies is set to 1
    # grep -q used to check if the pattern exists in the file
    capture "Checking session.use_only_cookies setting..."
    if ! grep -q '^session.use_only_cookies = 1' /etc/php/8.3/apache2/php.ini; then
        # Log a message if the session.use_only_cookies setting is not set to 1
        capture "session.use_only_cookies setting is not set to 1." "WARNING"
        capture "Adjusting session.use_only_cookies to 1..."
        # String substitution to adjust php.ini session.use_only_cookies setting
        # -i flag to edit the file in place
        if ! sed -i 's|^session.use_only_cookies =.*|session.use_only_cookies = 1|' /etc/php/8.3/apache2/php.ini; then
            # Log an error if the session.use_only_cookies setting is not adjusted
            capture "Failed to adjust session.use_only_cookies setting." "ERROR"
            exit $ERROR
        fi
        capture "session.use_only_cookies setting adjusted successfully."
    else
        capture "session.use_only_cookies setting is already set to 1."
    fi

    # Check if session.cookie_httponly is set to 1
    # grep -q used to check if the pattern exists in the file
    capture "Checking session.cookie_httponly setting..."
    if ! grep -q '^session.cookie_httponly = 1' /etc/php/8.3/apache2/php.ini; then
        # Log a message if the session.cookie_httponly setting is not set to 1
        capture "session.cookie_httponly setting is not set to 1." "WARNING"
        capture "Adjusting session.cookie_httponly to 1..."
        # String substitution to adjust php.ini session.cookie_httponly setting
        # -i flag to edit the file in place
        if ! sed -i 's|^session.cookie_httponly =.*|session.cookie_httponly = 1|' /etc/php/8.3/apache2/php.ini; then
            # Log an error if the session.cookie_httponly setting is not adjusted
            capture "Failed to adjust session.cookie_httponly setting." "ERROR"
            exit $ERROR
        fi
        capture "session.cookie_httponly setting adjusted successfully."
    else
        capture "session.cookie_httponly setting is already set to 1."
    fi

    # Check if session.cookie_samesite is set to Lax
    # grep -q used to check if the pattern exists in the file
    capture "Checking session.cookie_samesite setting..."
    if ! grep -q '^session.cookie_samesite = Lax' /etc/php/8.3/apache2/php.ini; then
        # Log a message if the session.cookie_samesite setting is not set to Lax
        capture "session.cookie_samesite setting is not set to Lax." "WARNING"
        capture "Adjusting session.cookie_samesite to Lax..."
        # String substitution to adjust php.ini session.cookie_samesite setting
        # -i flag to edit the file in place
        if ! sed -i 's|^session.cookie_samesite =.*|session.cookie_samesite = Lax|' /etc/php/8.3/apache2/php.ini; then
            # Log an error if the session.cookie_samesite setting is not adjusted
            capture "Failed to adjust session.cookie_samesite setting." "ERROR"
            exit $ERROR
        fi
        capture "session.cookie_samesite setting adjusted successfully."
    else
        capture "session.cookie_samesite setting is already set to Lax."
    fi

    #Enable Apache2 modules
    capture "Enabling Apachew rewrite module..."
    if ! a2enmod rewrite; then
        # Log an error if the rewrite module is not enabled
        capture "Failed to enable rewrite module." "ERROR"
        exit $ERROR
    fi
    capture "Rewrite module enabled successfully."
    capture "Enabling Apache2 headers module..."
    if ! a2enmod headers; then
        # Log an error if the headers module is not enabled
        capture "Failed to enable headers module." "ERROR"
        exit $ERROR
    fi
    capture "Headers module enabled successfully."

    # Download a health check endpoint for Apache from s3 bucket
    capture "Downloading health check endpoint for Apache..."
    if ! aws s3 cp s3://"$BUCKET_NAME"/html/health /var/www/html/health; then
        # Log an error if the health check endpoint is not downloaded
        capture "Failed to download health check endpoint." "ERROR"
        exit $ERROR
    fi
    capture "Health check endpoint downloaded successfully."

    # Enable Apache2 service
    capture "Enabling Apache2 service..."
    if ! systemctl enable apache2; then
        # Log an error if the Apache2 service is not enabled
        capture "Failed to enable Apache2 service." "ERROR"
        exit $ERROR
    fi
    capture "Apache2 service enabled successfully."

    # Start Apache2 service
    capture "Starting Apache2 service..."
    if ! systemctl start apache2; then
        # Log an error if the Apache2 service is not started
        capture "Failed to start Apache2 service." "ERROR"
        exit $ERROR
    fi
    capture "Apache2 service started successfully."

    capture "Apache web server configured successfully."
}

# Function to download and extract Joomla CMS
get_joomla() {
    capture "Installing Joomla CMS..."
    
    # Download the Joomla CMS zip file using curl and save it to /tmp directory
    # -L flag to follow redirects -o flag to specify the output file
    capture "Downloading Joomla CMS..."
    if ! curl -L -o /tmp/joomla.zip https://downloads.joomla.org/cms/joomla5/5-3-0/Joomla_5-3-0-Stable-Full_Package.zip?format=zip; then 
        # Log an error if the Joomla CMS is not downloaded
        capture "Failed to download Joomla CMS." "ERROR"
        exit $ERROR
    fi
    capture "Joomla CMS downloaded successfully."

    # Unzip the Joomla CMS
    # -o flag to overwrite existing files -d flag to specify the destination directory
    # -qq flag to suppress output
    capture "Unzipping Joomla CMS..."
    if ! unzip -q -o /tmp/joomla.zip -d /tmp/joomla/; then
        # Log an error if the Joomla CMS is not unzipped
        capture "Failed to unzip Joomla CMS." "ERROR"
        exit $ERROR
    fi
    capture "Joomla CMS unzipped successfully."
}

 configure_joomla() {
    capture "Configuring Joomla CMS..."

    # Retrieve RDS endpoint from SSM Parameter Store as a local variable
    capture "Retrieving RDS endpoint from SSM..."
    local RDS_ENDPOINT=$(aws ssm get-parameter --name "/AcmeLabs/Blog/Rds/DBInstance/Endpoint" --query "Parameter.Value" --output text)

    # Validate RDS endpoint is not an empty string
    validate_string "$RDS_ENDPOINT" "Failed to retrieve RDS endpoint." "RDS endpoint retrieved successfully." show

    # Retrieve database credentials from Secrets Manager as a local variable
    capture "Retrieving database credentials from Secrets Manager..."
    local DB_CREDENTIALS=$(aws secretsmanager get-secret-value --secret-id AcmeLabsBlogRDSMySQL1 --query "SecretString" --output text)
    
    # Validate database credentials is not an empty string
    validate_string "$DB_CREDENTIALS" "Failed to retrieve database credentials." "Database credentials retrieved successfully." hide

    # Parse the database username from the retrieved credentials as local variable
    # -r flag to output raw strings
    capture "Parsing database credentials for username..."
    local DB_USERNAME=$(echo $DB_CREDENTIALS | jq -r '.username')

    # Validate database username is not an empty string
    validate_string "$DB_USERNAME" "Failed to retrieve database username." "Database username retrieved successfully." show

    # Parse the database password from the retrieved credentials as local variable
    # -r flag to output raw strings
    capture "Parsing database credentials for password..."
    local DB_PASSWORD=$(echo $DB_CREDENTIALS | jq -r '.password')

    # Validate database password is not an empty string
    validate_string "$DB_PASSWORD" "Failed to retrieve database password." "Database password retrieved successfully." hide

    # Define the database name as a local variable
    capture "Setting database name..."
    local DB_NAME="toontown"

    # Validate database name is not an empty string
    validate_string "$DB_NAME" "Failed to set database name." "Database name set successfully." show

    # Retrieve Joomla Admin credentials from Secrets Manager as a local variable
    capture "Retrieving Joomla Admin credentials from Secrets Manager..."
    local JOOMLA_ADMIN_CREDENTIALS=$(aws secretsmanager get-secret-value --secret-id AcmeLabsBlogAdmin --query "SecretString" --output text)

    # Validate Joomla Admin credentials is not an empty string
    validate_string "$JOOMLA_ADMIN_CREDENTIALS" "Failed to retrieve Joomla Admin credentials." "Joomla Admin credentials retrieved successfully." hide

    # Parse the Joomla Admin username and password from the retrieved credentials as local variables
    # -r flag to output raw strings
    capture "Parsing Joomla Admin username..."
    local JOOMLA_ADMIN_USERNAME=$(echo $JOOMLA_ADMIN_CREDENTIALS | jq -r '.username')

    # Validate Joomla Admin username is not an empty string
    validate_string "$JOOMLA_ADMIN_USERNAME" "Failed to retrieve Joomla Admin username." "Joomla Admin username retrieved successfully." show

    # Parse the Joomla Admin password from the retrieved credentials as a local variable
    capture "Parsing Joomla Admin password..."
    local JOOMLA_ADMIN_PASSWORD=$(echo $JOOMLA_ADMIN_CREDENTIALS | jq -r '.password')

    # Validate Joomla Admin password is not an empty string
    validate_string "$JOOMLA_ADMIN_PASSWORD" "Failed to retrieve Joomla Admin password." "Joomla Admin password retrieved successfully." hide

    # Running php script to programatically install Joomla
    capture "Running php script to programatically install Joomla..."

    php /tmp/joomla/installation/joomla.php install \
        --site-name "AcmeLabs Blog" \
        --admin-user "Roger Rabbit" \
        --admin-username "roger" \
        --admin-password "$JOOMLA_ADMIN_PASSWORD" \
        --admin-email "rogerrabbit@acmelabs.cloud" \
        --db-type mysqli \
        --db-host "$RDS_ENDPOINT" \
        --db-user "$DB_USERNAME" \
        --db-pass "$DB_PASSWORD" \
        --db-name "$DB_NAME" \
        --db-prefix loony_ \
        --db-encryption 0 \
        --no-interaction

    validate_command "Failed to run php script to programatically install Joomla." "Php script to programatically install Joomla ran successfully." enable

    # Move Joomla files to the web root directory
    # -f flag to force the move
    capture "Moving Joomla files to the web root directory..."
    if ! mv -f /tmp/joomla/* /var/www/html/; then
        # Log an error if the Joomla files are not moved
        capture "Failed to move Joomla files to the web root directory." "ERROR"
        exit $ERROR
    fi
    capture "Joomla files moved to the web root directory successfully."

    # Set ownership for Joomla CMS directories & files
    # -R flag to apply recursively
    capture "Setting ownership for Joomla CMS..."
    if ! chown -R www-data:www-data /var/www/html/; then
        # Log an error if the ownership are not set
        capture "Failed to set ownership for Joomla CMS." "ERROR"
        exit $ERROR
    fi
    capture "Ownership for Joomla CMS set successfully."

    # Set permissions for Joomla CMS directories
    capture "Setting permissions for Joomla CMS directories..."
    if ! find /var/www/html/ -type d -exec chmod 755 {} \;; then
        # Log an error if the permissions are not set
        capture "Failed to set permissions for Joomla CMS directories." "ERROR"
        exit $ERROR
    fi
    capture "Permissions for Joomla CMS directories set successfully."

    # Set permissions for Joomla CMS files
    capture "Setting permissions for Joomla CMS files..."
    if ! find /var/www/html/ -type f -exec chmod 644 {} \;; then
        # Log an error if the permissions are not set
        capture "Failed to set permissions for Joomla CMS files." "ERROR"
        exit $ERROR
    fi
    capture "Permissions for Joomla CMS files set successfully."

    # Set the Joomla CMS live site URL
    capture "Setting Joomla CMS live site URL..."

    php /var/www/html/cli/joomla.php config:set live_site="https://blog.acmelabs.cloud"

    validate_command "Failed to set Joomla CMS live site URL." "Joomla CMS live site URL set successfully." disable

    capture "Joomla CMS configured successfully."
}

# Function to create archive of Joomla CMS 
# Upload to S3 bucket
create_joomla_archive() {
    capture "Creating archive of Joomla CMS..."

    # Stop Apache2 service
    capture "Stopping Apache2 service..."
    if ! systemctl stop apache2; then
        # Log an error if the Apache2 service is not stopped
        capture "Failed to stop Apache2 service." "ERROR"
        exit $ERROR
    fi
    capture "Apache2 service stopped successfully."

    # Create an archive of the Joomla CMS
    # -c flag to create a new archive -z flag to compress the archive -f flag to specify the output file
    if ! tar -czf /tmp/joomla.tar.gz /var/www/html/; then
        # Log an error if the archive is not created
        capture "Failed to create archive of Joomla CMS." "ERROR"
        exit $ERROR
    fi
    capture "Archive of Joomla CMS created successfully."

    # Upload the archive to the S3 bucket
    capture "Uploading archive of Joomla CMS to S3 bucket..."
    if ! aws s3 cp /tmp/joomla.tar.gz s3://"$BUCKET_NAME"/html/; then
        # Log an error if the archive is not uploaded
        capture "Failed to upload archive of Joomla CMS to S3 bucket." "ERROR"
        exit $ERROR
    fi
    capture "Archive of Joomla CMS uploaded to S3 bucket successfully."

    # Validate the archive was uploaded to S3 bucket
    local S3_OBJECT_URL="https://$BUCKET_NAME.s3.amazonaws.com/html/joomla.tar.gz"
    capture "Validating archive was uploaded to S3 bucket..."
    if ! aws s3api head-object --bucket "$BUCKET_NAME" --key "html/joomla.tar.gz" > /dev/null 2>&1; then
        # Log an error if the archive was not uploaded
        capture "Failed to validate archive was uploaded to S3 bucket." "ERROR"
        exit $ERROR
    fi
    capture "Archive of Joomla CMS validated successfully."
    capture "Joomla CMS archive URL: $S3_OBJECT_URL"
}

# Function to check EC2 instance state
get_instance_state() {
    capture "Checking EC2 instance state..."

    # Define local variables for this function
    local RETRY_COUNT=0
    local MAX_RETRIES=30
    local INSTANCE_STATE=""

    # Wait for the instance to reach a running state
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text)

        if [ "$INSTANCE_STATE" == "running" ]; then
            capture "EC2 instance is in a running state."
            return 0
        else
            capture "EC2 instance is not in a running state. Current state: $INSTANCE_STATE. Retrying in 5 seconds..."
            sleep 5
            RETRY_COUNT=$((RETRY_COUNT + 1))
        fi
    done
    # Log an error if the instance did not reach running state after max retries
    capture "EC2 instance did not reach running state after $MAX_RETRIES attempts." "ERROR"
    exit $ERROR
}

# Function to check EC2 instance health status
get_instance_health_status() {
    capture "Checking EC2 instance health status..."

    # Define local variables for this function
    local RETRY_COUNT=0
    local MAX_RETRIES=30
    local INSTANCE_HEALTH_STATUS=""

    # Wait for the instance health status to become OK
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        INSTANCE_HEALTH_STATUS=$(aws ec2 describe-instance-status --instance-ids "$INSTANCE_ID" --query 'InstanceStatuses[0].InstanceStatus.Status' --output text)

        if [ "$INSTANCE_HEALTH_STATUS" == "ok" ]; then
            capture "EC2 instance health status is OK."
            return 0
        else
            capture "EC2 instance health status is not OK. Current status: $INSTANCE_HEALTH_STATUS. Retrying in 5 seconds..."
            sleep 5
            RETRY_COUNT=$((RETRY_COUNT + 1))
        fi
    done
    # Log an error if the instance health status did not become OK after max retries
    capture "EC2 instance health status did not become OK after $MAX_RETRIES attempts." "ERROR"
    exit $ERROR
}

# Function to create an AMI from the instance
create_ami() {
    capture "Creating AMI from the instance..."

    # Create an AMI from the instance
    local AMI_ID=$(aws ec2 create-image --instance-id "$INSTANCE_ID" --name "AcmeLabs-Blog-Ubuntu24-AMI" --no-reboot --query 'ImageId' --output text)

    # Validate AMI ID is not an empty string
    validate_string "$AMI_ID" "Failed to create AMI." "AMI created successfully." show

    # Tag the created AMI
    capture "Tagging the created AMI..."
    if ! aws ec2 create-tags --resources "$AMI_ID" --tags Key=Name,Value=AcmeLabs-Blog-Ubuntu24-AMI; then
        # Log an error if the AMI is not tagged
        capture "Failed to tag the AMI." "ERROR"
        exit $ERROR
    fi
    capture "AMI tagged successfully."

    # Wait for the AMI to become available
    capture "Waiting for the AMI to become available..."
    while true; do
        local AMI_STATUS=$(aws ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].State' --output text)
        if [ "$AMI_STATUS" == "available" ]; then
            capture "AMI is now available."
            break
        fi
        capture "AMI status: $AMI_STATUS, waiting..."
        sleep 5
    done

    # Log the AMI ID into SSM Parameter Store
    capture "Storing the AMI ID in SSM Parameter Store..."
    if ! aws ssm put-parameter --name "/AcmeLabs/Blog/Ami/Ubuntu24/Id" --value "$AMI_ID" --type String --overwrite; then
        # Log an error if the AMI ID is not stored in SSM Parameter Store
        capture "Failed to store the AMI ID in SSM Parameter Store." "ERROR"
        exit $ERROR
    fi
    capture "AMI ID stored successfully in SSM Parameter Store."
}

# Function to terminate the EC2 instance
terminate_instance() {
    capture "Terminating the EC2 instance..."

    if ! aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"; then
        # Log an error if the instance is not terminated
        capture "Failed to terminate the EC2 instance." "ERROR"
        exit $ERROR
    fi

    capture "EC2 instance terminated successfully."
}

# Main execution
get_logging
get_running
get_os_updates_and_upgrade
get_packages
congifure_efs
configure_apache_server
get_joomla
configure_joomla
create_joomla_archive
get_instance_state
get_instance_health_status
create_ami
terminate_instance

# Log the completion of our script
capture "Startup script completed successfully!"
exit $SUCCESS
