# Edge Toolset

## Setup osbuild and osbuild-composer mock repo

        $ ./mock_repo.sh <osbuild-composer commit sha> <osbuild commit sha>

## Build OpenStack CentOS Stream image

        $ cd playbook
        $ VAULT_PASSWORD=foobar TEST_OS=centos-stream-8 ARCH=x86_64 ansible-playbook -v -i inventory image-build.yaml
