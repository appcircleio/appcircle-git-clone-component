#!/bin/bash
set -e

LOCAL_REPOSITORY_PATH=''
GIT_URL=''
BRANCH=''
TAG=''
COMMIT=''
SUBMODULE=true
LFS=true
REFERENCE=''
IS_SPECIFIC_COMMIT=false
GIT_EXTRA_PARAMS=''
for i in "$@"
do
case $i in
    -c=*|--commit=*)
    COMMIT="${i#*=}"
    shift # past argument=value
    ;;
    -t=*|--tag=*)
    TAG="${i#*=}"
    shift # past argument=value
    ;;
    -b=*|--branch=*)
    BRANCH="${i#*=}"
    shift # past argument=value
    ;;
    -g=*|--gitURL=*)
    GIT_URL="${i#*=}"
    shift # past argument=value
    ;;
    -l=*|--localPath=*)
    LOCAL_REPOSITORY_PATH="${i#*=}"
    shift # past argument=value
    ;;
    --lfs=*)
    LFS="${i#*=}"
    shift # past argument=value
    ;;
    --submodule=*)
    SUBMODULE="${i#*=}"
    shift # past argument=value
    ;;
    --extraParams=*)
    shift
    GIT_EXTRA_PARAMS="${i#*=}"
    ;;
    --authType=*)
    GIT_PROVIDER_AUTH_TYPE="${i#*=}"
    shift
    ;;
    --authToken=*)
    GIT_PROVIDER_TOKEN="${i#*=}"
    shift
    ;;
    --default)
    DEFAULT=YES
    shift # past argument with no value
    ;;
    *)
          # unknown option
    ;;
esac
done

if [ -z "${LOCAL_REPOSITORY_PATH}" ]; then
        echo "localPath should not null or empty"
        exit 1
fi

if [ -z "${GIT_URL}" ]; then
        echo "gitURL should not null or empty"
        exit 1
fi

(
    cd $LOCAL_REPOSITORY_PATH
    
    function fill(){
        if [ ! -z "${COMMIT}" ]
        then
            echo "Commit = ${COMMIT}"
            IS_SPECIFIC_COMMIT=true
            REFERENCE="${COMMIT}"
        elif [ ! -z "${BRANCH}" ]
        then
            echo "Branch = ${BRANCH}"
            REFERENCE="${BRANCH}"
        elif [ ! -z "${TAG}" ]
        then
            echo "Tag = ${TAG}"
            REFERENCE="${TAG}"
        else
            echo "At least one of commit, tag or branch should not null or empty"
            exit 1
        fi
    }

    function runCommand(){
     echo $@
     $@
    }

    runCommand git --version
    runCommand git lfs --version
    runCommand git init
    runCommand git remote add origin "${GIT_URL}"
    runCommand git config gc.auto 0
    runCommand git remote set-url origin "${GIT_URL}"
    runCommand git remote set-url --push origin "${GIT_URL}"
    if [ "$LFS" = true ] ; then
        runCommand git lfs install --local
        runCommand git config remote.origin.lfsurl "${GIT_URL}/info/ls"
        runCommand git config remote.origin.lfspushurl "${GIT_URL}/info/ls"
    fi

    if [[ "${GIT_PROVIDER_AUTH_TYPE}" == "Bearer" ]]; then
        if [ -z "$GIT_PROVIDER_TOKEN" ]; then
            echo "Error: GIT_PROVIDER_TOKEN is required when GIT_PROVIDER_AUTH_TYPE is set to 'Bearer'"
            exit 1
        fi

        runCommand git config --local --add http."${GIT_URL}".extraHeader "Authorization: Bearer ${GIT_PROVIDER_TOKEN}"
    fi

    if [ ! -z "${GIT_EXTRA_PARAMS}" ] ; then

        gitUrlDomain=$(echo "$GIT_URL" | sed -e 's|^\(.*://[^/]*\).*|\1|')
        echo "adding extra http header :  git config --local --add http.${gitUrlDomain}.extraHeader \"Authorization: Basic *********\""
        git config --local --add http."${gitUrlDomain}".extraHeader "Authorization: Basic ${GIT_EXTRA_PARAMS}"
    fi

    fill

    if [ "$IS_SPECIFIC_COMMIT" = true ]; then
        if [ ! -z "${BRANCH}" ]; then
            runCommand git fetch origin "${BRANCH}"
        else
            runCommand git fetch
        fi
    else
        runCommand git ls-remote "${GIT_URL}" "${REFERENCE}"
        REFERENCE=$(git ls-remote "${GIT_URL}" "${REFERENCE}" | awk {'print $1'})
        runCommand git fetch --tags --prune --progress --no-recurse-submodules origin "${REFERENCE}" --depth=1
    fi

    if [ "$LFS" = true ] ; then
        runCommand git lfs fetch origin "${REFERENCE}"
    fi
    runCommand git checkout --progress --force "${REFERENCE}" 

    if [ "$SUBMODULE" = true ] ; then

         if [ ! -z "${GIT_EXTRA_PARAMS}" ] ; then
            gitUrlDomain=$(echo "$GIT_URL" | sed -e 's|^\(.*://[^/]*\).*|\1|')
            echo "adding extra global http header for submodule :  git config --local --add http.${gitUrlDomain}.extraHeader \"Authorization: Basic *********\""
            git config --global --add http."${gitUrlDomain}".extraHeader "Authorization: Basic ${GIT_EXTRA_PARAMS}"
        fi

        runCommand git submodule sync --recursive
        runCommand git submodule update --init --force --recursive

        if [ ! -z "${GIT_EXTRA_PARAMS}" ] ; then
            gitUrlDomain=$(echo "$GIT_URL" | sed -e 's|^\(.*://[^/]*\).*|\1|')
            echo "removing extra global http header for submodule :  git config --global --unset-all http.${gitUrlDomain}.extraHeader"
            git config --global --unset-all "http.${gitUrlDomain}.extraHeader"
            
        fi

    fi
    
    runCommand git remote set-url origin "${GIT_URL}"
    runCommand git remote set-url --push origin "${GIT_URL}"
    if [ "$LFS" = true ] ; then
        runCommand git config --unset-all remote.origin.lfsurl
        runCommand git config --unset-all remote.origin.lfspushurl
    fi
)
exit 0
