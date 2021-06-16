# Edge Toolset

## Setup osbuild and osbuild-composer mock repo

        $ ./mock_repo.sh <osbuild-composer commit sha> <osbuild commit sha>

## Build OpenStack CentOS Stream image

        $ cd playbook
        $ VAULT_PASSWORD=foobar TEST_OS=centos-stream-8 ARCH=x86_64 ansible-playbook -v -i inventory image-build.yaml

## Deploy OpenStack VM for Edge testing

        $ cd playbook
        $ VAULT_PASSWORD=foobar TEST_OS=centos-stream-8 ARCH=x86_64 ansible-playbook -v -i inventory vm-deploy.yaml

## Configuration

You can set these environment variables to run test

    TEST_OS            The OS to run the tests in.  Currently supported values:
                           "rhel-8-4"
                           "rhel-8-5"
                           "centos-stream-8"
                           "fedora-34"
    ARCH               The arch to build image and run test on.  Currently supported values:
                           "x86_64"
    VAULT_PASSWORD     Decrypt "files/clouds-yaml"
