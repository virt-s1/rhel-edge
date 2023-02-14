#!/bin/bash

# Workaround for bug https://bugzilla.redhat.com/show_bug.cgi?id=2168089
/usr/libexec/fdo/fdo-owner-onboarding-server &
/usr/libexec/fdo/fdo-serviceinfo-api-server
