#!/usr/bin/env bash

set -e  

# Check required environment variables
if [ -z "$GITHUB_USERNAME" ] || [ -z "$GITHUB_REPO" ] || [ -z "$GITHUB_TOKEN" ]; then  
    echo "Missing required environment variables GITHUB_USERNAME or GITHUB_REPO or GITHUB_TOKEN"  
    exit 1  
fi  

# Build GitHub repository clone URL with token
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"  

# Check and create directories
mkdir -p ./data ./github_data

# Clone repository
echo "Cloning repository..."  
git clone "$REPO_URL" ./github_data || {  
    echo "Clone failed, please check if GITHUB_USERNAME, GITHUB_REPO and GITHUB_TOKEN are correct."  
    exit 1  
}  

if [ -f ./github_data/webui.db ]; then
    mv ./github_data/webui.db ./data/webui.db
    echo "Successfully pulled from GitHub repository"
else
    echo "webui.db not found in GitHub repository, will push during sync"
fi

# Define sync function
sync_to_github() {  
    while true; do  
        # Enter repository directory
        cd ./github_data  

        # Configure Git user information
        git config user.name "AutoSync Bot"  
        git config user.email "autosync@bot.com"  

        # Ensure on correct branch
        git checkout main || git checkout master  

        # Copy latest database file
        if [ -f ../data/webui.db ]; then
          cp ../data/webui.db ./webui.db
        else
          echo "Local file ../data/webui.db not exists."
        fi

        # Check for changes
        if [[ -n $(git status -s) ]]; then  
            # Add all changes
            git add webui.db  
            
            # Commit changes
            git commit -m "Auto sync webui.db $(date '+%Y-%m-%d %H:%M:%S')"  
            
            # Push to remote repository
            git push origin HEAD || {  
                echo "Push failed, waiting to retry..."  
                sleep 10  
                git push origin HEAD  || {  
                    echo "Retry failed, abandoning push."    
                }
            }  
            
            echo "Database synced to GitHub"  
        else  
            echo "No database changes detected"  
        fi  

        # Return to parent directory
        cd ..  

        # Get wait time from environment variable, default is 7200 seconds
        SYNC_INTERVAL=${SYNC_INTERVAL:-7200}
        echo "Waiting ${SYNC_INTERVAL} seconds before next sync..."
        sleep $SYNC_INTERVAL
    done  
}  

# Start sync process in background
sync_to_github &

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "$SCRIPT_DIR" || exit

# Add conditional Playwright browser installation
if [[ "${RAG_WEB_LOADER_ENGINE,,}" == "playwright" ]]; then
    if [[ -z "${PLAYWRIGHT_WS_URI}" ]]; then
        echo "Installing Playwright browsers..."
        playwright install chromium
        playwright install-deps chromium
    fi

    python -c "import nltk; nltk.download('punkt_tab')"
fi

KEY_FILE=.webui_secret_key

PORT="${PORT:-8080}"
HOST="${HOST:-0.0.0.0}"
if test "$WEBUI_SECRET_KEY $WEBUI_JWT_SECRET_KEY" = " "; then
  echo "Loading WEBUI_SECRET_KEY from file, not provided as an environment variable."

  if ! [ -e "$KEY_FILE" ]; then
    echo "Generating WEBUI_SECRET_KEY"
    # Generate a random value to use as a WEBUI_SECRET_KEY in case the user didn't provide one.
    echo $(head -c 12 /dev/random | base64) > "$KEY_FILE"
  fi

  echo "Loading WEBUI_SECRET_KEY from $KEY_FILE"
  WEBUI_SECRET_KEY=$(cat "$KEY_FILE")
fi

if [[ "${USE_OLLAMA_DOCKER,,}" == "true" ]]; then
    echo "USE_OLLAMA is set to true, starting ollama serve."
    ollama serve &
fi

if [[ "${USE_CUDA_DOCKER,,}" == "true" ]]; then
  echo "CUDA is enabled, appending LD_LIBRARY_PATH to include torch/cudnn & cublas libraries."
  export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:/usr/local/lib/python3.11/site-packages/torch/lib:/usr/local/lib/python3.11/site-packages/nvidia/cudnn/lib"
fi

# Check if SPACE_ID is set, if so, configure for space
if [ -n "$SPACE_ID" ]; then
  echo "Configuring for HuggingFace Space deployment"
  if [ -n "$ADMIN_USER_EMAIL" ] && [ -n "$ADMIN_USER_PASSWORD" ]; then
    echo "Admin user configured, creating"
    WEBUI_SECRET_KEY="$WEBUI_SECRET_KEY" uvicorn open_webui.main:app --host "$HOST" --port "$PORT" --forwarded-allow-ips '*' &
    webui_pid=$!
    echo "Waiting for webui to start..."
    while ! curl -s http://localhost:8080/health > /dev/null; do
      sleep 1
    done
    echo "Creating admin user..."
    curl \
      -X POST "http://localhost:8080/api/v1/auths/signup" \
      -H "accept: application/json" \
      -H "Content-Type: application/json" \
      -d "{ \"email\": \"${ADMIN_USER_EMAIL}\", \"password\": \"${ADMIN_USER_PASSWORD}\", \"name\": \"Admin\" }"
    echo "Shutting down webui..."
    kill $webui_pid
  fi

  export WEBUI_URL=${SPACE_HOST}
fi

WEBUI_SECRET_KEY="$WEBUI_SECRET_KEY" exec uvicorn open_webui.main:app --host "$HOST" --port "$PORT" --forwarded-allow-ips '*'
