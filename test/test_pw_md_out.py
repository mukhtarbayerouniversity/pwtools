from pwtools.parse import PwMDOutputFile
from pwtools import common
from pwtools.constants import Bohr, Ang
from pwtools.test.tools import assert_attrs_not_none, adae

def test_pw_md_out():    
    filename = 'files/pw.md.out'
    common.system('gunzip %s.gz' %filename)
    alat = 5.9098 # Bohr
    pp1 = PwMDOutputFile(filename=filename, use_alat=True)
    pp1.parse()
    none_attrs = [\
        'coords_frac',
        ]
    assert_attrs_not_none(pp1, none_attrs=none_attrs)
    traj1 = pp1.get_traj()
    assert_attrs_not_none(traj1)

    pp2 = PwMDOutputFile(filename=filename, 
                         use_alat=False,
                         units={'length': alat*Bohr/Ang})
    pp2.parse()                         
    assert_attrs_not_none(pp2, none_attrs=none_attrs)
    
    # Skip coords and cell b/c they are modified by self.alat and
    # pp1.alat = 1.0, pp2.alat = 5.9098
    attr_lst = common.pop_from_list(pp1.attr_lst, ['coords', 'cell'])
    adae(pp1.__dict__, pp2.__dict__, keys=attr_lst)         
    
    traj2 = pp2.get_traj()
    adae(traj1.__dict__, traj2.__dict__, keys=traj1.attr_lst)

    pp3 = PwMDOutputFile(filename=filename)
    assert alat == pp3.get_alat() # self.use_alat=True default
   
    common.system('gzip %s' %filename)
