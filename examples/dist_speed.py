# Compare speed of distance calculation: numpy vs. fortran. The Fortran version
# is ~10x faster. See also test/test_distsq_frac.py .

import numpy as np
from pwtools import _flib, crys, timer

def pydist(arr, cell, mic=0):
    distvecs_frac = arr[:,None,:] - arr[None,...]
    if mic == 1:
        distvecs_frac = crys.min_image_convention(distvecs_frac)
    distvecs = np.dot(distvecs_frac, cell)
    distsq = (distvecs**2.0).sum(axis=2)
    return distsq, distvecs, distvecs_frac

def fdist(arr, cell, mic=0):
    return _flib.distsq_frac(arr, cell, mic=mic)

if __name__ == '__main__':
    
    mic = 1

    arr = np.random.rand(100,3)
    cell = np.random.rand(3,3)*3
    tt = timer.TagTimer()
    nn = 1000
    tt.t('py')
    for ii in range(nn):
        pydist(arr,cell,mic)
    tt.pt('py')
    tt.t('f')
    for ii in range(nn):
        fdist(arr,cell,mic)
    tt.pt('f')

        
