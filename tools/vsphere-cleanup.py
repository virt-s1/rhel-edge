import os
import datetime

# Prepare govc environment
GOVC_CREDENTIALS = "GOVC_URL=%s GOVC_USERNAME=%s GOVC_PASSWORD=%s GOVC_INSECURE=%s" % (
    os.environ.get("GOVC_URL"),
    os.environ.get("GOVC_USERNAME"),
    os.environ.get("GOVC_PASSWORD"),
    os.environ.get("GOVC_INSECURE")
)
DATACENTER_70 = "Datacenter7.0"
# DATACENTER_67 = "Datacenter6.7"

class VM:
    def __init__(self, name, date, dc) -> None:
        self.name = name
        self.date = date
        self.dc = dc
    def expired(self):
        vm_date = datetime.datetime.strptime(self.date, "%Y-%m-%d %H:%M:%S")
        current_date = datetime.datetime.now()
        age = current_date - vm_date
        if age.days >= 2:
            return True
        return False
    def destroy(self):
        cmd = GOVC_CREDENTIALS + " govc vm.destroy -dc=%s %s" % (self.dc, self.name)
        os.system(cmd)

# Get all edge vms in vsphere environment
def get_all_vms():
    vms = []
    name = ""
    date = ""
    # Get edge vms in datacenter7.0
    cmd = GOVC_CREDENTIALS + " govc vm.info -dc=%s *-70 > 70vm.txt" % (DATACENTER_70)
    os.system(cmd)
    with open("70vm.txt", "r") as f:
        for line in f:
            if "Name" in line.strip():
                name = line[5:].strip()
            if "Boot time" in line.strip():
                date = line[12:].strip()[0:19]
                vms.append(VM(name, date, DATACENTER_70))
    # # Get edge vms in datacenter6.7
    # cmd = GOVC_CREDENTIALS + " govc vm.info -dc=%s *-67 > 67vm.txt" % (DATACENTER_67)
    # os.system(cmd)
    # with open("67vm.txt", "r") as f:
    #     for line in f:
    #         if "Name" in line.strip():
    #             name = line[5:].strip()
    #         if "Boot time" in line.strip():
    #             date = line[12:].strip()[0:19]
    #             vms.append(VM(name, date, DATACENTER_67))
    return vms

if __name__ == "__main__":
    vms = get_all_vms()
    if len(vms) == 0:
        print("No edge vm found in vsphere, exit now")
        exit()

    print("Found existing edge vms:")
    for vm in vms:
        print("> Name:%s, Date:%s" % (vm.name, vm.date))

    print("Check vm date and destroy expired vm")
    destroy = False
    for vm in vms:
        if vm.expired():
            destroy = True
            vm.destroy()
            print("> VM %s is destroyed (date: %s)" % (vm.name, vm.date))
    if not destroy:
        print("No expire edge vm found, exit now")
