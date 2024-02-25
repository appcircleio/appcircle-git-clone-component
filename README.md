# Appcircle _Git Clone_ component

Clones the Git repository to the build agent with the given arguments.

You can use this component with the following options:
- git branch name (latest commit)
- git branch name and git commit hash
- git tag

## Required Input Variables

- `AC_GIT_URL`: Specifies the Git URL of the project repository.

## Optional Inputs Variables

- `AC_GIT_COMMIT`: Specifies the commit of the Git repository to be built.
- `AC_GIT_BRANCH`: Specifies the branch of the Git repository to be built.
- `AC_GIT_LFS`: Used to specify whether large files will be downloaded. Defaults to `false`.
- `AC_GIT_TAG`: Tag of the repository.
- `AC_GIT_SUBMODULE`: Used to specify whether the submodule should be cloned.
- `AC_GIT_CACHE_CREDENTIALS`: If this set to true, the credentials will be cached to memory. This can be useful if the same credentials are used for multiple repositories.
- `AC_GIT_EXTRA_PARAMS`: If this set, sends extra parameter for git requests.

## Output Variables

- `AC_REPOSITORY_DIR`: Repository Directory. Specifies outputs the cloned repository directory.

## Required Steps

- There is no required step that needs to be run afterward for this step to work as expected.

## Preceding Steps

-  Activate SSH Key

## Following Steps

- There are no subsequent steps advised to be run for this step to work as expected.
