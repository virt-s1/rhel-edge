# Edge Toolset

## Setup osbuild and osbuild-composer mock repo

        $ ./mock_repo.sh <osbuild-composer commit sha> <osbuild commit sha>

## Download and Upload OpenStack CentOS Stream image

        $ cd playbook
        $ TEST_OS=centos-stream-8 ARCH=x86_64 ansible-playbook -v -i inventory image-build.yaml

## Deploy OpenStack VM for Edge testing

        $ cd playbook
        $ TEST_OS=centos-stream-8 ARCH=x86_64 ansible-playbook -v -i inventory vm-deploy.yaml

## Deploy Edge container image on OpenShift 4

        $ oc login --token=<token> --server=https://api.ocp4.prod.psi.redhat.com:6443
        $ oc oc process -f tools/edge-stage-server-template.yaml | oc apply -f -

## Setup RPM repo for source import

        # Please copy or move all RPM packages, which are used by source, into /tmp/rpms
        $ ./mock_source.sh

## Configuration

You can set these environment variables to run test

    TEST_OS            The OS to run the tests in.  Currently supported values:
                           "rhel-8-6"
                           "rhel-8-7"
                           "rhel-9-0"
                           "rhel-9-1"
                           "centos-stream-8"
                           "centos-stream-9"
                           "fedora-34"
                           "fedora-35"
    ARCH               The arch to build image and run test on.  Currently supported values:
                           "x86_64"
