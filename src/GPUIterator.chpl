/* Copyright (c) 2019, Rice University
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:
1.  Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.
2.  Redistributions in binary form must reproduce the above
     copyright notice, this list of conditions and the following
     disclaimer in the documentation and/or other materials provided
     with the distribution.
3.  Neither the name of Rice University
     nor the names of its contributors may be used to endorse or
     promote products derived from this software without specific
     prior written permission.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

module GPUIterator {
    use Time;
    use BlockDist;

    config param debugGPUIterator = true;

    // Utility functions
    inline proc computeSubranges(whole: range(?),
                                 CPUPercent: int(64)) {

      const CPUnumElements = (whole.size * CPUPercent * 1.0 / 100.0) : int(64);
      const CPUhi = (whole.low + CPUnumElements - 1);
      const CPUrange = whole.low..CPUhi;
      const GPUlo = CPUhi + 1;
      const GPUrange = GPUlo..whole.high;

      return (CPUrange, GPUrange);
    }

    inline proc computeChunk(r: range, myChunk, numChunks)
      where r.stridable == false {

      const numElems = r.length;
      const elemsPerChunk = numElems/numChunks;
      const mylow = r.low + elemsPerChunk*myChunk;
      if (myChunk != numChunks - 1) {
	    return mylow..#elemsPerChunk;
      } else {
	    return mylow..r.high;
      }
    }

    iter createTaskAndYield(param tag: iterKind,
                            r: range(?),
                            CPUrange: range(?),
                            GPUrange: range(?),
                            GPUWrapper: func(int, int, int, void))
      where tag == iterKind.leader {

      if (CPUrange.size == 0) {
        const myIters = GPUrange;
        if (debugGPUIterator) then
          writeln("GPU portion: ", myIters);
        GPUWrapper(myIters.translate(-r.low).first, myIters.translate(-r.low).last, GPUrange.length);
      } else if (GPUrange.size == 0) {
        const numTasks = here.maxTaskPar;
        if (debugGPUIterator) then
          writeln("CPU portion: ", CPUrange, " by ", numTasks, " tasks");
        coforall tid in 0..#numTasks {
          const myIters = computeChunk(CPUrange, tid, numTasks);
          yield (myIters.translate(-r.low),);
        }
      } else {
        cobegin {
          // CPU portion
          {
            const numTasks = here.maxTaskPar;
            if (debugGPUIterator) then
              writeln("CPU portion: ", CPUrange, " by ", numTasks, " tasks");
            coforall tid in 0..#numTasks {
              const myIters = computeChunk(CPUrange, tid, numTasks);
              yield (myIters.translate(-r.low),);
            }
          }
          // GPU portion
          {
            const myIters = GPUrange;
            if (debugGPUIterator) then
              writeln("GPU portion: ", myIters);
            GPUWrapper(myIters.translate(-r.low).first, myIters.translate(-r.low).last, GPUrange.length);
          }
        }
      }
    }

    iter createTaskAndYield(param tag: iterKind,
                            r: range(?),
                            CPUrange: range(?),
                            GPUrange: range(?),
                            GPUWrapper: func(int, int, int, void))
      where tag == iterKind.standalone {

      if (CPUrange.size == 0) {
        const myIters = GPUrange;
        if (debugGPUIterator) then
          writeln("GPU portion: ", myIters);
        GPUWrapper(myIters.translate(-r.low).first, myIters.translate(-r.low).last, GPUrange.length);
      } else if (GPUrange.size == 0) {
        const numTasks = here.maxTaskPar;
        if (debugGPUIterator) then
          writeln("CPU portion: ", CPUrange, " by ", numTasks, " tasks");
        coforall tid in 0..#numTasks {
          const myIters = computeChunk(CPUrange, tid, numTasks);
          for i in myIters do
            yield i;
        }
      } else {
        cobegin {
          // CPU portion
          {
            const numTasks = here.maxTaskPar;
            if (debugGPUIterator) then
              writeln("CPU portion: ", CPUrange, " by ", numTasks, " tasks");
            coforall tid in 0..#numTasks {
              const myIters = computeChunk(CPUrange, tid, numTasks);
              for i in myIters do
                yield i;
            }
          }
          // GPU portion
          {
            const myIters = GPUrange;
            if (debugGPUIterator) then
              writeln("GPU portion: ", myIters);
            GPUWrapper(myIters.translate(-r.low).first, myIters.translate(-r.low).last, GPUrange.length);
          }
        }
      }
    }

    iter createTaskAndYield(r: range(?),
                            CPUrange: range(?),
                            GPUrange: range(?),
                            GPUWrapper: func(int, int, int, void)) {
      halt("This is dummy");
    }

    // leader (block distributed domains)
    iter GPU(param tag: iterKind,
             D: domain,
             GPUWrapper: func(int, int, int, void),
             CPUPercent: int = 0
             )
       where tag == iterKind.leader
       && isRectangularDom(D)
       && D.dist.type <= Block {

      if (debugGPUIterator) {
        writeln("GPUIterator (leader, block distributed)");
      }

      coforall loc in D.targetLocales() do on loc {
        for subdom in D.localSubdomains() {
          const r = subdom.dim(1);
          const portions = computeSubranges(r, CPUPercent);
          for i in createTaskAndYield(tag, r, portions(1), portions(2), GPUWrapper) {
            yield i;
          }
        }
      }
    }

    // follower (block distributed domains)
    iter GPU(param tag: iterKind,
             D: domain,
             GPUWrapper: func(int, int, int, void),
             CPUPercent: int = 0,
             followThis
             )
      where tag == iterKind.follower
      && followThis.size == 1
      && isRectangularDom(D)
      && D.dist.type <= Block {

      const lowBasedIters = followThis(1).translate(D.low);

      if (debugGPUIterator) {
        writeln("GPUIterator (follower, block distributed)");
        writeln("Follower received ", followThis, " as work chunk; shifting to ",
                lowBasedIters);
      }

      for i in lowBasedIters do
        yield i;
    }

    // standalone (block distributed domains)
    iter GPU(param tag: iterKind,
             D: domain,
             GPUWrapper: func(int, int, int, void),
             CPUPercent: int = 0
             )
      where tag == iterKind.standalone
      && isRectangularDom(D)
      && D.dist.type <= Block {

      if (debugGPUIterator) {
        writeln("GPUIterator (standalone distributed)");
      }

      // for each locale
      coforall loc in D.targetLocales() do on loc {
        for subdom in D.localSubdomains() {
          if (debugGPUIterator) then writeln(here, " (", here.name,  ") is responsible for ", subdom);
          const r = subdom.dim(1);
          const portions = computeSubranges(r, CPUPercent);

          for i in createTaskAndYield(tag, r, portions(1), portions(2), GPUWrapper) {
            yield i;
          }
        }
      }
    }

    // serial iterator (block distributed domains)
    iter GPU(D: domain,
             GPUWrapper: func(int, int, int, void),
             CPUPercent: int = 0
             )
      where isRectangularDom(D)
      && D.dist.type <= Block {

      if (debugGPUIterator) {
        writeln("GPUIterator (serial distributed)");
      }
      for i in D {
        yield i;
      }
    }

    // leader (range)
    iter GPU(param tag: iterKind,
             r: range(?),
             GPUWrapper: func(int, int, int, void),
             CPUPercent: int = 0
             )
      where tag == iterKind.leader {

      if (debugGPUIterator) then
	    writeln("In GPUIterator (leader range)");

      const portions = computeSubranges(r, CPUPercent);
      for i in createTaskAndYield(tag, r, portions(1), portions(2), GPUWrapper) {
        yield i;
      }
    }

    // follower
    iter GPU(param tag: iterKind,
             r:range(?),
             GPUWrapper: func(int, int, int, void),
             CPUPercent: int = 0,
             followThis
             )
      where tag == iterKind.follower
      && followThis.size == 1 {

      const lowBasedIters = followThis(1).translate(r.low);

      if (debugGPUIterator) {
        writeln("GPUIterator (follower)");
        writeln("Follower received ", followThis, " as work chunk; shifting to ",
                lowBasedIters);
      }

      for i in lowBasedIters do
        yield i;
    }

    // standalone (range)
    iter GPU(param tag: iterKind,
             r: range(?),
             GPUWrapper: func(int, int, int, void),
             CPUPercent: int = 0
             )
  	  where tag == iterKind.standalone {

      if (debugGPUIterator) then
	    writeln("In GPUIterator (standalone)");

      const portions = computeSubranges(r, CPUPercent);
      for i in createTaskAndYield(tag, r, portions(1), portions(2), GPUWrapper) {
        yield i;
      }
    }

    // serial iterators (range)
    iter GPU(r:range(?),
             GPUWrapper: func(int, int, int, void),
             CPUPercent: int = 0
             ) {
      if (debugGPUIterator) then
        writeln("In GPUIterator (serial)");

      for i in r do
        yield i;
    }
}