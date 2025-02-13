% CHANNELDATA - Store and process channel data
%
% The ChannelData class stores an N-dimensional datacube and it's temporal 
% axes and provides overloaded methods for manipulating and plotting the 
% data. The ChannelData must have a t0 value consistent with the
% definition of t0 in QUPS to be used with other beamforming algorithms in
% QUPS. Most methods that affect the time axes, such as zeropad or filter, 
% will shift the time axes accordingly.
%
% The underlying datacube can be N-dimensional as long as the first three
% dimensions contain the (fast) time, receive and transmit dimensions. All 
% data must share the same sampling frequency fs, but the start time t0 may
% vary across any dimension(s) except for the time and receiver dimensions.
% For example, if each transmit has a different t0, this can be represented
% by an array of size [1,1,M] where M is the number of transmits.
% 
% The underlying numeric type of the data can be cast by appending 'T' to
% the type (e.g. singleT(chd) produces a ChannelData) whereas the datacube 
% itself can be cast using the numeric type constructor (e.g. single(chd) 
% produces an array). Overloaded methods are also provided to cast to a 
% gpuArray or tall type. The time axes is also cast to the corresponding
% type. This enables MATLABian casting rules to apply to the object, which
% can be used by other functions.
% 
% See also SEQUENCE TRANSDUCER ULTRASOUNDSYSTEM

classdef ChannelData < matlab.mixin.Copyable

    properties
        data    % channel data (T x N x M x F x ...)
        t0 = 0  % start time (1 x 1 x [1|M] x [1|F] x ...)
        fs = 1  % sampling frequency (scalar)
    end
    properties(Access=public)
        order = 'TNM'; % data order: T: time, N: receive, M: transmit
    end
    properties (Dependent)
        time    % time axis (T x 1 x [1|M] x [1|F] x ...)
    end
    properties(Hidden, Dependent)
        T       % number of time samples
        N       % number of receiver channels
        M       % number of transmits
    end

    % constructor/destructor
    methods
        function chd = ChannelData(varargin)
            % CHANNELDATA - Construct a ChannelData object
            %
            % ChannelData(Name1, Value1, ...) constructs a channel data
            % object via name/value pairs.
            %
            % 

            % set each property by name-value pairs
            for i = 1:2:nargin, chd.(lower(varargin{i})) = varargin{i+1}; end
        end
    end
    
    % copyable overloads
    methods(Access=protected)
        function chd = copyElement(chd)
            chd = ChannelData('data',chd.data,'fs', chd.fs,'t0',chd.t0,'order',chd.order);
        end
    end

    % conversion functions
    methods
        function uchannel_data = QUPS2USTB(chd, seq, xdc, fmod)
            % QUPS2USTB - Create a USTB channel data object
            % 
            % channel_data = QUPS2USTB(chd, seq, xdc) creates a USTB 
            % compatible uff.channel_data object from the ChannelData chd, 
            % Sequence seq, and Tranducer xdc. USTB must be on the path.
            %
            % channel_data = QUPS2USTB(..., fmod) sets the modulation 
            % frequency to fmod. The default is 0.
            % 
            % 
            if nargin < 4, fmod = 0; end
            chd = rectifyDims(chd); % make sure it's in order 'TNM' first
            uchannel_data = uff.channel_data(...
                'sampling_frequency', chd.fs, ...
                'sound_speed', seq.c0, ...
                'initial_time', 0, ...
                'modulation_frequency', fmod, ...
                'sequence', seq.QUPS2USTB(xdc, chd.t0), ...
                'probe', xdc.QUPS2USTB(), ...
                'data', gather(chd.data(:,:,:,:)) ... limit to 4 dimensions
                );
        end
    
        % scaling
        function chd = scale(chd, kwargs)
            % SCALE - Scale units
            %
            % chd = SCALE(chd, 'time', factor) scales the temporal
            % properties by factor. This simultaneously converts in time 
            % and in frequency, for example from seconds to microseconds 
            % and hertz to megahertz.
            %
            % Example:
            %
            % % Create a ChannelData object
            % chd = ChannelData('data', rand(2^8), 'fs', 1e6, 't0', -5e-6); % s, Hz
            %
            % % convert from hertz to megahertz
            % chd = scale(chd, 'time', 1e6); % us, MHz
            % chd.fs
            % chd.t0
            %

            arguments
                chd ChannelData
                kwargs.time (1,1) double
            end
            chd = copy(chd);
            if isfield(kwargs, 'time')
                w = kwargs.time;
                % scale time (e.g. s -> us / Hz -> MHz)
                [chd.fs, chd.t0] = deal(chd.fs/w, w*chd.t0);
            end
        end
        
        function s = obj2struct(chd)
            % OBJ2STRUCT - Convert a QUPS object into a native MATLAB struct
            %
            % chd = OBJ2STRUCT(chd) converts the ChannelData chd and all
            % of it's properties into native MATLAB structs.
            %
            % Example:
            %
            % % Create a ChannelData
            % chd = ChannelData()
            %
            % % convert to a MATLAB struct
            % chd = obj2struct(chd)
            %
            arguments
                chd ChannelData
            end

            W = warning('off', "MATLAB:structOnObject"); % squash warnings
            s = struct(chd); % convert scan
            s.class = class(chd); % append class info
            warning(W); % restore warnings
        end
    end

    methods(Static)
        function chd = UFF(uchannel_data, seq, xdc)
            arguments
                uchannel_data (1,1) uff.channel_data
                seq (1,1) Sequence = Sequence.UFF(uchannel_data.sequence, uchannel_data.sound_speed);
                xdc Transducer {mustBeScalarOrEmpty} = Transducer.UFF(uchannel_data.probe); % only needed for FSA
            end
            
            % get the start time in QUPS format
            t0 = [uchannel_data.sequence.delay];
            switch seq.type
                case 'FSA', t0 = t0 - vecnorm(xdc.positions,2,1) ./ seq.c0; % delay transform from element to origin for FSA
                case 'VS',  t0 = t0 - vecnorm(seq.focus,    2,1) ./ seq.c0; % transform for focal point to origin
                case 'FC',  t0 = t0 - vecnorm(seq.focus,    2,1) ./ seq.c0; % transform for focal point to origin
                case 'DV',  warning("QUPS:UFF:unvalidatedTransform", "Unvalidated import: please validate."); % TODO: validate
                            t0 = t0 + vecnorm(seq.focus,    2,1) ./ seq.c0; % transform for focal point to origin
                case 'PW' % no action necessary
            end

            % collapse if unique
            if isalmostn(t0, repmat(mean(t0), size(t0))), t0 = mean(t0); end

            % Create the ChannelData
            chd = ChannelData( ...
                't0', swapdim(t0,2,3), ...
                'fs', uchannel_data.sampling_frequency, ...
                'data', uchannel_data.data, ...
                'order', 'TNM' ... 
                );
        end
    
        function [chd, fmod, smode] = Verasonics(RcvData, Receive, Trans, kwargs)
            % VERASONICS - Construct ChannelData from a Verasonics struct
            %
            % chd = ChannelData.Verasonics(RcvData, Receive) constructs an
            % array of ChannelData chd for each receive buffer referenced
            % in the Verasonics 'RcvData' and 'Receive' struct. The data
            % has size (time x acq x channel x frame).
            % 
            % Within each buffer, the sampling frequency, samples per
            % acquisition, demodulation frequency, and the number of
            % acquisitions per frame must be constant for each buffer.
            %
            % chd = ChannelData.Verasonics(RcvData, Receive, Trans) maps
            % channels to transducer elements and returns the data with
            % size (time x acq x elem x frame).
            % 
            % [chd, fmod] = ChannelData.Verasonics(...) additionally
            % returns an array of the demodulation frequencies fmod.
            %
            % [chd, fmod, smode] = ChannelData.Verasonics(...) additionally
            % returns an array the sample modes for each buffer.
            %
            % [...] = ChannelData.Verasonics(..., 'frames', f) specfies the
            % frames. The default is unique([Receive.framenum]).
            %
            % [...] = ChannelData.Verasonics(..., 'buffer', b) specfies
            % the buffer indices b corresponding to each element of
            % RcvData. The default is unique([Receive.bufnum], 'stable').
            %
            % [...] =  ChannelData.Verasonics(..., 'insert0s', false)
            % disables 0-insertion to replace missing samples when the 
            % buffer sample mode is one of ["BS100BW", "BS67BW", "BS50BW"]. 
            % The default is true.
            % 
            % Example:
            % chd = ChannelData.Verasonics(RcvData, Receive, Trans);
            % chd = hilbert(singleT(chd));
            % figure; animate(chd.data, 'fs', 5);
            % 
            % See also SEQUENCE.VERASONICS WAVEFORM.VERASONICS
            arguments
                RcvData cell
                Receive struct
                Trans struct {mustBeScalarOrEmpty} = struct.empty
                kwargs.buffer (1,:) {mustBeNumeric, mustBeInteger} = unique([Receive.bufnum], 'stable')
                kwargs.frames (1,:) {mustBeNumeric, mustBeInteger} = unique([Receive.framenum])
                kwargs.insert0s (1,1) logical = true
            end

            % validate the RcvData
            cellfun(@mustBeNumeric, RcvData);

            % for each buffer
            B = numel(kwargs.buffer);
            for i = B:-1:1
                % get relevant receive info
                b = kwargs.buffer(i);
                Rx = Receive((b == [Receive.bufnum]) & ismember([Receive.framenum], kwargs.frames)); % filter by buffer and frame
                if isempty(Rx) 
                    warning("No data found for buffer " + kwargs.buffer(i) + "."); 
                    [smode(i), fmod(i), chd(i)] = deal("N/A", nan, ChannelData('order','TMNF'));
                    continue;
                end

                % constants
                fs = unique([Rx.decimSampleRate]); % get sampling frequency
                fm = unique([Rx.demodFrequency ]); % get demodulation frequency
                fr = unique([Rx.framenum]); % frames
                sm = unique({Rx.sampleMode}); % sampling mode
                F = numel(fr); % number of frames

                % validate sample mode
                if isscalar(sm), sm = string(sm);
                else           , sm = "N/A";
                    warning( ...
                        "QUPS:Verasonics:InconsistentAcquisitionSize", ...
                        "Buffer " + kwargs.buffer(i) + " contains multiple sample modes." ...
                        )
                end
                
                % validate sizing
                dupCnt = @(x) unique(groupcounts(x(:))); % count duplicates
                if any(F ~= cellfun(dupCnt, {[Rx.acqNum], [Rx.startSample], [Rx.endSample]}))
                    error( ...
                        "QUPS:Verasonics:InconsistentAcquisitionSize", ...
                        "Unable to parse buffer " + kwargs.buffer(i) + "." ...
                        + " The number of acquisitions and the acquisition sample indices must be constant across all frames." ...
                        ); 
                end

                % validate ordering
                Rx  = reshape( Rx, [], F); % -> acquisitions by frames
                fnm = reshape([Rx.framenum], size(Rx));
                acq = reshape([Rx.acqNum  ], size(Rx));
                A = numel(unique(acq)); % number of acquisitions
                if ~(all(acq == acq(:,1),'all') && all(fnm == fnm(1,:),'all'))
                    error( ...
                        "QUPS:Verasonics:InconsistentAcquisitionOrder", ...
                        "Unable to parse buffer " + b  + "." ...
                        + " The acquisition numbers and frame numbers must be separable" ...
                        + " when formed as a " + A + " x " + F + " array." ...
                        );
                end

                j = cellfun(@colon, {Rx.startSample}, {Rx.endSample}, 'UniformOutput', false); % sample indices
                j = unique([j{:}], 'stable'); % should be identical across acquisitions

                % load data (time x acq x channel x frame)
                x = RcvData{i}(j,:,fr); % only extract the filled portion
                x = reshape(x, [], A, size(x,2), size(x,3)); % (T x A x Np x F)

                % if Trans exists, make chd.N match Trans
                if ~isempty(Trans)
                    % get aperture indexing
                    if isfield(Rx, 'aperture')
                        aps = Trans.HVMux.ApertureES;
                        as = reshape([Rx.aperture], size(Rx)); % apertures
                        if(~all(as(:,1) == as, 'all'))
                            error( ...
                                "QUPS:Verasonics:InconsistentAcquisitionOrder", ...
                                "Unable to parse buffer " + b  + "." ...
                                + " The apertures must be identical across frames." ...
                                );
                        end
                        as = as(:,1);
                    else
                        aps = Trans.ConnectorES;
                        as = 1;
                    end

                    % pre-allocate output
                    ysz = size(x);
                    ysz(2) = Trans.numelements;
                    y = zeros(ysz, 'like', x);

                    % load into output
                    for a = unique(as)' % for each aperture
                        j = a == as; % matching aperture
                        k = aps(:,a); % channel indices
                        y(:,j,k~=0,:) = x(:,j,k(k~=0),:); % load
                    end
                    x = y; % (time x acq x elem x frame)
                end

                % transform the sampled data depending on the sample mode
                if kwargs.insert0s
                    switch sm
                        case "NS200BW", [N, K] = deal(0, 1); % fully sampled      - insert N=0 0s every K=1 samples
                        case "BS100BW", [N, K] = deal(2, 2); % [1,1,0,0,]         - insert N=2 0s every K=2 samples
                        case "BS67BW",  [N, K] = deal(2, 1); % [1,0,0,]           - insert N=2 0s every K=1 samples
                        case "BS50BW",  [N, K] = deal(6, 2); % [1,1,0,0,0,0,0,0,] - insert N=6 0s every K=2 samples
                        otherwise,      [N, K] = deal(0, 1); % unknown            - insert N=0 0s every K=1 samples
                    end
                    dsz = size(x); % data size
                    x = reshape(x, [K, dsz(1)/K, dsz(2:end)]); % set sample singles/pairs in dim 1
                    x(end+(1:N),:) = 0; % insert N 0s
                    x = reshape(x, [(K+N) * (dsz(1)/K), dsz(2:end)]); % return to original dimensions
                end
                
                % construct ChannelData
                % TODO: account for different sample modes
                chd(i) = ChannelData('data', x, 'fs', 1e6*fs, 'order', 'TMNF');
                fmod(i) = fm; % assume only one demod frequency
                smode(i) = sm; % assume only one sample mode 
            end
        end
    end

    % helper functions
    methods(Hidden)
        function chd = applyFun2Props(chd, fun), 
            chd = copy(chd);
            [chd.t0, chd.fs, chd.data] = deal(fun(chd.t0), fun(chd.fs), fun(chd.data));
        end
        function chd = applyFun2Data(chd, fun), chd = copy(chd); [chd.data] = dealfun(fun, chd.data); end
        function chd = applyFun2Dim(chd, fun, dim, varargin),
            chd = copy(chd); % copy semantics
            chd.data = matlab.tall.transform(@dimfun, chd.data, varargin{:}); % apply function in dim 1; % set output data

            % dim1 mapping function: dim d gets sent to dim 1 and back.
            function x = dimfun(x, varargin)
                x = swapdim(x, 1, dim); % send dim d to dim 1
                x = fun(x, varargin{:}); % operate in dim 1
                x = swapdim(x, 1, dim); % send dim d back
            end
        end
    end

    % data type overloads
    methods
        function chd = gather(chd)  , chd = applyFun2Data(chd, @gather); end
        % return the underlying data to it's native base type
        function chd = gpuArray(chd), chd = applyFun2Data(chd, @gpuArray); end
        % cast underlying type to gpuArray
        function chd = tall(chd)    , chd = applyFun2Data(chd, @tall); end
        % cast underlying type to tall
        function chd = sparse(chd)  , chd = applyFun2Data(chd, @sparse); end
        % cast underlying type to sparse
        function chd = doubleT(chd) , chd = applyFun2Data(chd, @double); end
        % cast underlying type to double
        function chd = singleT(chd) , chd = applyFun2Data(chd, @single); end
        % cast underlying type to single
        function chd =   halfT(chd) , chd = applyFun2Data(chd, @halfT); end
        % cast underlying type to half
        function chd =  int64T(chd) , chd = applyFun2Data(chd, @int64); end
        % cast underlying type to int64
        function chd = uint64T(chd) , chd = applyFun2Data(chd, @uint64); end
        % cast underlying type to uint64
        function chd =  int32T(chd) , chd = applyFun2Data(chd, @int32); end
        % cast underlying type to int32
        function chd = uint32T(chd) , chd = applyFun2Data(chd, @uint32); end
        % cast underlying type to uint32
        function chd =  int16T(chd) , chd = applyFun2Data(chd, @int16); end
        % cast underlying type to int16
        function chd = uint16T(chd) , chd = applyFun2Data(chd, @uint16); end
        % cast underlying type to uint16
        function chd =   int8T(chd) , chd = applyFun2Data(chd, @int8); end
        % cast underlying type to int8
        function chd =  uint8T(chd) , chd = applyFun2Data(chd, @uint8); end
        % cast underlying type to uint8
        function T = classUnderlying(chd), try T = classUnderlying(chd.data); catch, T = class(chd.data); end, end % revert to class if undefined
        % underlying class of the data or class of the data
        function T = underlyingType(chd), try T = underlyingType(chd.data); catch, T = class(chd.data); end, end % R2020b+ overload
        % underlying type of the data or class of the data
        function tf = isreal(chd), tf = isreal(chd.data); end
        % whether the underlying data is real
        function tf = istall(chd), tf = istall(chd.data); end
        % whether the underlying data is tall
    end
    
    % implicit casting: functions that request a numeric type may call
    % these functions
    methods
        function x = double(chd), x = double(chd.data); end
        % convert to a double array
        function x = single(chd), x = single(chd.data); end
        % convert to a single array
        function x =   half(chd), x =   half(chd.data); end
        % convert to a half array
        function x =  int64(chd), x =  int64(chd.data); end
        % convert to a int64 array
        function x = uint64(chd), x = uint64(chd.data); end
        % convert to a uint64 array
        function x =  int32(chd), x =  int32(chd.data); end
        % convert to a int32 array
        function x = uint32(chd), x = uint32(chd.data); end
        % convert to a uint32 array
        function x =  int16(chd), x =  int16(chd.data); end
        % convert to a int16 array
        function x = uint16(chd), x = uint16(chd.data); end
        % convert to a uint16 array
        function x =   int8(chd), x =   int8(chd.data); end
        % convert to a int8 array
        function x =  uint8(chd), x =  uint8(chd.data); end
        % convert to a uint8 array
    end

    % math overloads
    methods
        function c = times(a, b)
            if isa(a, 'ChannelData') && ~isa(b, 'ChannelData')
                c = copy(a); c.data = times(a.data, b);
            elseif ~isa(a, 'ChannelData') && isa(b, 'ChannelData')
                c = copy(b); c.data = times(a, b.data);
            else % if both are ChannelData, we check that the time axis is identical
                if all(a.order == b.order) && all(a.t0 == b.t0, 'all') && a.fs == b.fs
                    c = copy(a); c.data = times(a.data, b.data);
                else
                    error('ChannelData does not match - cannot perform arithmetic')
                end                
            end
        end
    
        function c = plus(a, b)
            if isa(a, 'ChannelData') && ~isa(b, 'ChannelData')
                c = copy(a); c.data = plus(a.data, b);
            elseif ~isa(a, 'ChannelData') && isa(b, 'ChannelData')
                c = copy(b); c.data = plus(a, b.data);
            else % if both are ChannelData, we check that the time axis is identical
                if all(a.order == b.order) && all(a.t0 == b.t0, 'all') && a.fs == b.fs
                    c = copy(a); c.data = plus(a.data, b.data);
                else
                    error('ChannelData does not match - cannot perform arithmetic')
                end                
            end
        end
    end

    % DSP overloads 
    methods
        function chd = downmix(chd, fc)
            % DOWNMIX - Shift a signal's spectrum down
            %
            % chd = DOWNMIX(chd, fc) mixes the data with a complex
            % exponential in order to shift the frequency spectrum of the
            % data down by fc.
            %
            % Downmixing can be combined with downsampling to reduce
            % the sampling frequency while retaining the information
            % content of the data. This process may be referred to as
            % demodulation.
            % 
            % Example:
            % % Simulate some data
            % us = UltrasoundSystem('fs', 100e6); % get a default system
            % us.tx = us.rx; % use the same transducer
            % targ = Scatterers('pos', [0;0;30e-3], 'c0', us.seq.c0); % define a point target
            % chd = greens(us, targ); % simulate the ChannelData
            % chd = zeropad(chd, 0, max(0, 2^10-chd.T)); % ensure at least 2^10 samples
            % 
            % % Downmix and downsample the data
            % fmod_max = max(abs(us.xdc.fc - us.xdc.bw)); % maximum demodulated frequency 
            % ratio = floor(us.fs / fmod_max / 2); % discrete downsampling factor
            % chdd = downmix(hilbert(chd), us.xdc.fc); % downmix
            % chdd = downsample(chdd, ratio); % downsample
            % 
            % % Image the data
            % figure; 
            % subplot(1,2,1);
            % imagesc(us.scan, mod2db(DAS(us, chd)));
            % colormap gray; colorbar; caxis([-60 0] + max(caxis));
            % title('Original sampling frequency');
            %
            % subplot(1,2,2);
            % imagesc(us.scan, mod2db(DAS(us, chdd, 'fmod', us.xdc.fc)));
            % colormap gray; colorbar; caxis([-60 0] + max(caxis));
            % title("Downsampled by " + ratio + "x");
            %
            % See also DOWNSAMPLE FILTER HILBERT FFT
            arguments
                chd ChannelData
                fc (1,1) {mustBeNumeric, mustBeFinite}
            end
            
            % copy semantics
            chd = copy(chd);
            
            % downmix directly with the temporal phasor
            chd.data = chd.data .* exp(-2i*pi*fc*chd.time);            
        end
        function D = getPassbandFilter(chd, bw, N)
            % GETPASSBANDFILTER Get a passband filter
            %
            % D = GETPASSBANDFILTER(chd, bw) creates a FIR bandpass 
            % digitalFilter object D with a passband between bw(1) and 
            % bw(end). It can be used to filter the ChannelData.
            %
            % D = GETPASSBANDFILTER(chd, bw, N) uses N coefficients. The
            % default is 25.
            %
            % See also DESIGNFILT DIGITALFILTER CHANNELDATA/FILTER
            % CHANNELDATA/FILTFILT CHANNELDATA/FFTFILT


            % defaults
            if nargin < 3, N = 25; end

            % make a
            D = designfilt('bandpassfir', ...
                'SampleRate',chd.fs, ...
                'FilterOrder', N, ...
                'CutoffFrequency1', bw(1), ...
                'CutoffFrequency2', bw(end), ...
                'DesignMethod', 'window' ...
                );
        end
        function D = getLowpassFilter(chd, cutoff, N)
            % GETPASSBANDFILTER Get a passband filter
            %
            % D = GETPASSBANDFILTER(chd, cutoff) creates a FIR bandpass
            % digitalFilter object D with a cutoff frequency cutoff. It can
            % be used to filter the ChannelData.
            %
            % D = GETPASSBANDFILTER(chd, cutoff, N) uses N coefficients.
            % The default is 25.
            %
            % See also DESIGNFILT DIGITALFILTER CHANNELDATA/FILTER
            % CHANNELDATA/FILTFILT CHANNELDATA/FFTFILT


            % defaults
            if nargin < 3, N = 25; end

            % make a
            D = designfilt('lowpassfir', ...
                'SampleRate',chd.fs, ...
                'FilterOrder', N, ...
                'CutoffFrequency', cutoff, ...
                'DesignMethod', 'window' ...
                );
        end
        function chd = filter(chd, D, dim)
            % FILTER Filter data with a digitalFilter
            %
            % chd = FILTER(chd, D) filters the channel data with the
            % digitalFilter D. Use DESIGNFILT to design a digital filter.
            %
            % chd = FILTER(chd, D, dim) applies the filter in dimension
            % dim. The default is the time dimension.
            %
            % See also DESIGNFILT DIGITALFILTER FILTER

            % hard error if we aren't given a digitalFilter
            assert(isa(D, 'digitalFilter'), "Expected a 'digitalFilter' but got a " + class(D) + " instead.");

            % defaults
            if nargin < 3, dim = chd.tdim; end

            % filter: always applied in dim 1
            chd = applyFun2Dim(chd, @(x) filter(D, x), dim);

            % get filter temporal correction
            switch D.ImpulseResponse
                case 'fir', L = filtord(D) / 2;
                case 'iir', L = filtord(D);
            end

            % adjust time axes
            if dim == chd.tdim
                chd.t0 = chd.t0 - L/chd.fs;
            end
        end
        function chd = filtfilt(chd, D, dim)
            % FILTFILT Filter data with a digitalFilter
            %
            % chd = FILTFILT(chd, D) filters the channel data with the
            % digitalFilter D. Use DESIGNFILT to design a digital filter
            %
            % chd = FILTFILT(chd, D, dim) applies the filter in dimension
            % dim. The default is the time dimension.
            %
            % See also DESIGNFILT DIGITALFILTER FILTFILT

            % hard error if we aren't given a digitalFilter
            assert(isa(D, 'digitalFilter'), "Expected a 'digitalFilter' but got a " + class(D) + " instead.");

            % defaults
            if nargin < 3, dim = chd.tdim; end

            % filter: always applied in dim 1
            chd = applyFun2Dim(chd, @(x) cast(filtfilt(D, double(x)), 'like', x), dim);
        end
        function chd = fftfilt(chd, D, dim)
            % FFTFILT Filter data with a digitalFilter
            %
            % chd = FFTFILT(chd, D) filters the channel data with the
            % digitalFilter D. Use DESIGNFILT to design a digital filter
            %
            % chd = FFTFILT(chd, D, dim) applies the filter in dimension
            % dim. The default is the time dimension.
            %
            % See also DESIGNFILT DIGITALFILTER FFTFILT

            % hard error if we aren't given a digitalFilter
            assert(isa(D, 'digitalFilter'), "Expected a 'digitalFilter' but got a " + class(D) + " instead.");
            
            % defaults
            if nargin < 3, dim = chd.tdim; end

            % filter: always applied in dim 1
            chd = applyFun2Dim(chd, @(x) reshape(cast(fftfilt(D, double(x(:,:))), 'like', x), size(x)), dim);

            % adjust time axes
            if dim == chd.tdim
                chd.t0 = chd.t0 - filtord(D)/2/chd.fs;
            end
        end
        function chd = hilbert(chd, N, dim)
            % HILBERT - overloads the hilbert function
            %
            % chd = HILBERT(chd) applies the hilbert function to the data
            % in the time dimension.
            %
            % chd = HILBERT(chd, N) computes the N-point Hilbert transform. 
            % The data is padded with zeros if it has less than N points, 
            % and truncated if it has more.
            %
            % chd = HILBERT(chd, N, dim) operates in dimension dim. The
            % default is the time dimension.
            %
            % See also HILBERT

            % parse inputs
            if nargin < 3, dim = chd.tdim; end
            if nargin < 2 || isempty(N), N = size(chd.data, dim); end

            if chd.tdim == 1 && ~isa(chd.data, 'halfT')
                % use MATLAB's optimized implementation
                chd = copy(chd); % copy semantics
                chd.data = hilbert(chd.data, N); % in-place
            else
                % otherwise apply natively to support all types
                chd = fft(chd, N, chd.tdim); % send to freq domain
                Nd2 = floor(N/2); % number of postive/negative frequencies
                w = [1; 2*ones([Nd2-1,1]); 1+mod(N,2); zeros([N-Nd2-1,1])]; % hilbert weight vector
                chd.data = chd.data .* shiftdim(w, 1-chd.tdim); % apply
                chd = ifft(chd, N, chd.tdim);
            end
        end
        function chd = fft(chd, N, dim)
            % FFT - overload of fft
            %
            % chd = FFT(chd) computes the fft of the channel data along the 
            % time axis. The time and frequency axes are unchanged.
            %
            % chd = FFT(chd, N) computes the N-point fft.
            %
            % chd = FFT(chd, N, dim) or FFT(chd, [], dim) operates along
            % dimension dim.
            %
            % See also FFT CHANNELDATA/FFTSHIFT

            % defaults
            if nargin < 3, dim = chd.tdim; end
            if nargin < 2 || isempty(N), N = size(chd.data, dim); end
            if istall(chd) && dim == 1, error('Cannot compute fft in the tall dimension.'); end
            chd = copy(chd);
            chd.data = matlab.tall.transform(@fft, chd.data, N, dim); % take the fourier transform
        end
        function chd = fftshift(chd, dim)
            % FFTSHIFT - overload of fftshift
            %
            % chd = FFTSHIFT(chd) swaps the left and right halves of the 
            % data along the time dimension. The time and frequency axes  
            % are unchanged.
            %
            % chd = FFTSHIFT(chd, dim) operates along dimension dim.
            %
            % See also FFTSHIFT CHANNELDATA/FFT 

            if nargin < 2, dim = chd.tdim; end
            if istall(chd) && dim == 1, error('Cannot compute fftshift in the tall dimension.'); end
            chd = copy(chd);
            chd.data = matlab.tall.transform(@fftshift, chd.data, dim);
        end
        function chd = ifft(chd, N, dim)
            % IFFT - overload of fft
            %
            % chd = IFFT(chd) computes the inverse fft of the channel data 
            % along the time axis. The time and frequency axes are 
            % unchanged.
            %
            % chd = IFFT(chd, N) computes the N-point inverse fft.
            %
            % chd = IFFT(chd, N, dim) or IFFT(chd, [], dim) operates along
            % dimension dim.
            %
            % See also IFFT CHANNELDATA/IFFTSHIFT


            % defaults
            if nargin < 3, dim = chd.tdim; end
            if nargin < 2 || isempty(N), N = size(chd.data, dim); end
            if istall(chd) && dim == 1, error('Cannot compute ifft in the tall dimension.'); end
            chd = copy(chd);
            chd.data = matlab.tall.transform(@ifft, chd.data, N, dim); % take the fourier transform
        end
        function chd = ifftshift(chd, dim)
            % IFFTSHIFT - overload of fftshift
            %
            % chd = IFFTSHIFT(chd) swaps the left and right halves of the 
            % data along the time dimension. The time and frequency axes  
            % are unchanged.
            %
            % chd = IFFTSHIFT(chd, dim) operates along dimension dim.
            %
            % IFFTSHIFT undoes the effects of fftshift
            % 
            % See also IFFTSHIFT CHANNELDATA/IFFT 
            if nargin < 2, dim = chd.tdim; end
            if istall(chd) && dim == 1, error('Cannot compute ifftshift in the tall dimension.'); end
            chd = copy(chd);
            chd.data = matlab.tall.transform(@ifftshift, chd.data, dim);
        end
        function chd = downsample(chd, ratio)
            % DOWNSAMPLE Downsample the ChannelData
            %
            % chd = DOWNSAMPLE(chd, ratio) downsamples the ChannelData to
            % reduce the sampling frequency by ratio.
            %
            % Example:
            % chd = ChannelData('data', rand([2^10,1]), 'fs', 8);
            % chd = downsample(chd, 4) % downsample by a factor of 4
            % 
            % See also RESAMPLE DOWNMIX
            arguments
                chd ChannelData
                ratio (1,1) {mustBePositive, mustBeInteger}
            end
            chd = copy(chd); % copy semantics
            chd = subD(chd, 1:ratio:chd.T, chd.tdim); % sub-index
            chd.fs(:) = chd.fs / ratio; % reduce sampling frequency
        end
        function chd = resample(chd, fs, varargin)
            % RESAMPLE - Resample the data in time
            %
            % chd = RESAMPLE(chd, fs) resamples the data at sampling
            % frequency fs. And returns a new ChannelData object.
            %
            % chd = RESAMPLE(chd, fs, ..., METHOD) specifies the method of 
            % interpolation. The default is linear interpolation.  
            % Available methods are:
            %   'linear' - linear interpolation
            %   'pchip'  - shape-preserving piecewise cubic interpolation
            %   'spline' - piecewise cubic spline interpolation
            %
            % chd = RESAMPLE(chd, fs, ..., arg1, arg2, ...) forwards 
            % arguments to MATLAB's RESAMPLE function
            %
            % See also RESAMPLE DOWNSAMPLE

            % save original data prototypes
            [Tt, Tf, Td] = deal(chd.t0, chd.fs, cast(zeros([0,0]), 'like', chd.data));
            
            % Make new ChannelData (avoid modifying the original)
            chd = copy(chd);

            % ensure numeric args are non-sparse, double
            chd = (doubleT(chd)); % data is type double
            fs = (double(fs)); % new frequency is type double
            inum = cellfun(@isnumeric, varargin); % all numeric inputs are type double
            varargin(inum) = cellfun(@double, varargin(inum), 'UniformOutput', false);

            % resample in time - no support for other dims: fs is required arg
            % [y, ty] = resample(chd.data, chd.time, fs, varargin{:}, 'Dimension', chd.tdim);
            % [chd.fs, chd.t0, chd.data] = deal(fs, ty(1), y);
            y = matlab.tall.transform(@resample, chd.data, chd.time, fs, varargin{:}, 'Dimension', chd.tdim);
            [chd.fs, chd.data] = deal(fs, y);

            % cast back to original type
            tmp = cellfun(@(x,T) cast(x, 'like', T), {chd.t0, chd.fs, chd.data}, {Tt, Tf, Td}, 'UniformOutput', false);
            [chd.t0, chd.fs, chd.data] = tmp{:};

        end
        function chd = real(chd)    , chd = applyFun2Data(chd, @real); end
        function chd = imag(chd)    , chd = applyFun2Data(chd, @imag); end
        function chd = abs(chd)     , chd = applyFun2Data(chd, @abs); end
        function chd = angle(chd)   , chd = applyFun2Data(chd, @angle); end
        function chd = rad2deg(chd) , chd = applyFun2Data(chd, @rad2deg); end
        function chd = deg2rad(chd) , chd = applyFun2Data(chd, @deg2rad); end
        function chd = mag2db(chd)  , chd = applyFun2Data(chd, @mag2db); end
        function chd = mod2db(chd)  , chd = applyFun2Data(chd, @mod2db); end
    end

    % DSP helpers
    methods
        function chd = zeropad(chd, B, A)
            % ZEROPAD - Zero pad the data in time
            %
            % chd = ZEROPAD(chd, B) prepends B zeros to the ChannelData 
            % data in time
            %
            % chd = ZEROPAD(chd, B, A) also appends A zeros to the 
            % ChannelData data in time
            %
            % When using this function, the time axis is adjusted.
            % 
            % See also CIRCSHIFT

            if nargin < 2 || isempty(B), B = 0; end
            if nargin < 3 || isempty(A), A = 0; end
            assert(A >= 0 && B >= 0, 'Data append or prepend size must be positive.');

            chd = copy(chd); % copy semantics
            if A == 0 && B == 0, return; end % short circuit
            % chd.data(end+(B+A),:) = 0; % append A + B zeros in time to the data
            s = repmat({':'}, [1,gather(ndims(chd.data))]); % splice in all other dimensions
            s{chd.tdim} = chd.T + (1:(B+A)); % expand by B+A in time dimension
            chd.data = subsasgn(chd.data,substruct('()',s),0); % call assignment - set to zero
            chd.data = matlab.tall.transform(@circshift, chd.data, B, chd.tdim); % shift B of the zeros to the front
            chd.t0 = chd.t0 - B ./ chd.fs; % shift start time for B of the zeros
        end
    
        function fc = estfc(chd)
            % ESTFC - Estimate the central frequency
            %
            % fc = ESTFC(chd) estimates the central frequency of the
            % ChannelData chd by choosing the mode of the maximum frequency
            % across all channels. This method should be updated with a
            % better heuristic. Alternatively, the central frequency may be
            % defined by the Waveform that was transmitted, the impulse
            % response of the Transducer(s), or the Transducer itself
            %
            % See also TRANSDUCER WAVEFORM SEQUENCE
            % TRANSDUCER/ULTRASOUNDTRANSDUCERIMPULSE


            f = chd.fs * ((0:chd.T-1)' ./ chd.T); % compute frequency axis
            y = fft(chd, [], chd.tdim); % compute fft
            z = argmax(abs(y.data), [], chd.tdim); % get peak over frequencies
            z = matlab.tall.transform(@mode, z, 2:gather(ndims(y.data))); % mode over non-tall dims
            fc = f(median(gather(z))); % select median over tall dims
        end
    
        function chd = rectifyt0(chd, interp, t0_)
            % RECTIFYT0 - Collapse t0 to a scalar
            %
            % chd = RECTIFYT0(chd) returns a ChannelData object with a
            % single value of t0 by resampling all channels onto a single
            % time axis. 
            %
            % chd = RECTIFYT0(chd, interp) specifices the interpolation
            % method as recognized by the sample function.
            %
            % See also CHANNELDATA/SAMPLE 

            if nargin < 2, interp = 'cubic'; end % default interpolation
            if nargin < 3, t0_ = min(chd.t0, [], 'all'); end % get global start time
            chd = copy(chd); % copy semantics
            if isscalar(chd.t0), return; end % short-circuit
            toff = chd.t0 - t0_; % get offset across upper dimensions
            npad = ceil(max(toff,[],'all') * chd.fs); % furthest sample containing data
            chd = zeropad(chd,0,npad); % extend time-axes
            tau = t0_ + swapdim(0:chd.T-1+npad,2,chd.tdim) ./ chd.fs; % get delays to resample all traces
            y = chd.sample(tau, interp); % resample
            chd.data = y; % make new object
            chd.t0 = t0_; % make new object
        end
    
        function y = sample(chd, tau, interp, w, sdim, fmod, apdim)
            % SAMPLE - Sample the channel data in time
            %
            % y = SAMPLE(chd, tau) samples the ChannelData chd at the times
            % given by the delays tau. 
            %
            % tau must have broadcastable sizing in the non-temporal
            % dimensions. In other words, in all dimensions d, either of
            % the following must hold
            %   1)   size(tau,d)    ==   size(chd.data,d) 
            %   2)  (size(tau,d) == 1 || size(chd.data,d) == 1)
            %
            % The underlying routines are optimized for compute
            % performance. See ChannelData/sample2sep or consider using a 
            % for-loop if memory is a concern.
            % 
            % y = SAMPLE(chd, tau, interp) specifies the interpolation
            % method. Interpolation is handled by the built-in interp1 
            % function. The available methods are:
            %
            %   'linear'   - (default) linear interpolation **
            %   'nearest'  - nearest neighbor interpolation **
            %   'next'     - next neighbor interpolation
            %   'previous' - previous neighbor interpolation
            %   'spline'   - piecewise cubic spline interpolation 
            %   'pchip'    - shape-preserving piecewise cubic interpolation
            %   'cubic'    - cubic convolution interpolation for ***
            %                uniformly-spaced data **
            %   'v5cubic'  - same as 'cubic' ***
            %   'makima'   - modified Akima cubic interpolation
            %   'freq'     - frequency domain sinc interpolation ****
            %   'lanczos3' - lanczos kernel with a = 3 **
            % 
            %    **   GPU support is enabled via interpd
            %    ***  GPU support is enabled via interp1
            %    **** GPU support is native
            % 
            % y = SAMPLE(chd, tau, interp, w) applies the weighting array w
            % via point-wise  multiplication after sampling the data. The  
            % dimensions must be compatible with the sampling array tau in 
            % the sampling dimension dim. The default is 1.
            % 
            % y = SAMPLE(chd, tau, interp, w, sdim) sums the data in the 
            % dimension(s) sdim after the weighting matrix has been applied.
            % The default is [] (no dimensions).
            % 
            % y = SAMPLE(chd, tau, interp, w, sdim, fmod) upmixes the data 
            % at a modulation frequency fmod. This undoes the effect of
            % downmixing at the same frequency.
            % 
            % y = SAMPLE(chd, tau, interp, w, sdim, fmod, apdim) specifies
            % the receive and transmit aperture dimensions of the sampling
            % array tau and weight array w. 
            % 
            % When this argument is used, the dimension of the data are 
            % lifted to (T x 1 x ... x 1 x N x M) where N and M are the 
            % receive and transmit aperture dimensions. The default is
            % [chd.ndim, chd.mdim]
            % 
            % See also CHANNELDATA/SAMPLE2SEP INTERP1 INTERPD INTERPF WSINTERPD CHANNELDATA/RECTIFYT0

            % defaults
            if nargin < 7, apdim = [chd.ndim, chd.mdim]; end
            if nargin < 6, fmod = 0; end
            if nargin < 5, sdim = [];           end
            if nargin < 4, w = 1;               end
            if nargin < 3, interp = 'linear';   end
            
            % move data up to match the sampling/apodization matrix
            D = max(3,ndims(chd.data));
            chd = swapdimD(chd, [chd.ndim, chd.mdim, 4:D], [apdim, max(apdim) + (1 : (D - 3))]);            

            % check condition that we can implicitly broadcast
            for d = setdiff(1:gather(ndims(tau)), chd.tdim) % all dims except time must match
                assert(any(gather(size(tau,d)) == gather(size(chd.data,d))) || ...
                            (1 == size(tau,d)  ||   1 == size(chd.data,d)), ...
                    'Delay size must match the data size (%i) or be singleton in dimension %i.',...
                    size(chd.data, d), d ...
                    );
            end

            % compute the integer delays (I x [1|N] x [1|M] x [1|F] x ...) (default order)
            ntau = (tau - chd.t0) .* chd.fs;

            % apply the modulation vector as weights
            omega = 2i*pi*fmod / chd.fs; % modulation phasor

            % dispatch
            if interp ~= "freq" 
                if istall(ntau) || istall(chd.data)
                    y = matlab.tall.transform(@wsinterpd, chd.data, ntau, chd.tdim, w, sdim, interp, 0, omega);
                else
                    y = wsinterpd(chd.data, ntau, chd.tdim, w, sdim, interp, 0, omega);
                end
            elseif interp == "freq"
                % extend data if necessary
                nwrap = min(0,floor(min(ntau,[],'all'))); % amount the signal is wrapped around from negative time
                next  = max(0, ceil(max(ntau,[],'all')) - chd.T-1); % amount the signal is extended in positive time
                chd = zeropad(chd, -nwrap, next); % extend signal to ensure we sample zeros
                y = interpf(chd.data, ntau, chd.tdim, w, sdim); % sample in the frequency domain
            end
        end
                
        function y = sample2sep(chd, tau1, tau2, interp, w, sdim, fmod, apdim)
            % SAMPLE2SEP - Sample the channel data with separable time delays
            %
            % y = SAMPLE2SEP(chd, tau1, tau2) samples the ChannelData chd
            % at the times given by separable delays tau = tau1 + tau2.
            %
            % tau must have broadcastable sizing in the non-temporal
            % dimensions. In other words, in all dimensions d, either of
            % the following must hold
            %   1)   size(tau,d)    ==   size(chd.data,d) 
            %   2)  (size(tau,d) == 1 || size(chd.data,d) == 1)
            %
            % The underlying routines are optimized for compute
            % performance with less memory overhead than ChannelData/sample.
            % If operating on a CPU, a parallel.ThreadPool will increase
            % performance considerably with minimal memory overhead.
            % 
            % y = SAMPLE2SEP(chd, tau1, tau2, interp) specifies the
            % interpolation method. Interpolation is handled by the
            % built-in interp1 function. The available methods are:
            %
            %   'linear'   - (default) linear interpolation **
            %   'nearest'  - nearest neighbor interpolation **
            %   'next'     - next neighbor interpolation
            %   'previous' - previous neighbor interpolation
            %   'spline'   - piecewise cubic spline interpolation 
            %   'pchip'    - shape-preserving piecewise cubic interpolation
            %   'cubic'    - cubic convolution interpolation for ***
            %                uniformly-spaced data **
            %   'v5cubic'  - same as 'cubic' ***
            %   'makima'   - modified Akima cubic interpolation
            %   'lanczos3' - lanczos kernel with a = 3 **
            % 
            %    **   GPU support is enabled via interpd
            %    ***  GPU support is enabled via interp1
            % 
            % y = SAMPLE2SEP(chd, tau1, tau2, interp, w) applies the
            % weighting array w via point-wise multiplication after
            % sampling the data. The dimensions must be compatible with the
            % sampling array tau in the sampling dimension dim. The default
            % is 1.
            % 
            % y = SAMPLE2SEP(chd, tau1, tau2, interp, w, sdim) sums the
            % data in the dimension(s) sdim after the weighting matrix has
            % been applied. The default is [] (no dimensions).
            % 
            % y = SAMPLE2SEP(chd, tau1, tau2, interp, w, sdim, fmod) 
            % upmixes the data at a modulation frequency fmod. This undoes
            % the effect of downmixing at the same frequency.
            % 
            % y = SAMPLE2SEP(chd, tau1, tau2, interp, w, sdim, fmod, apdim)
            % specifies the receive and transmit aperture dimensions of the
            % sampling array tau and weight array w. The default is 
            % [chd.ndim, chd.mdim]
            % 
            % When this argument is used, the dimension of the data are 
            % lifted to (T x 1 x ... x 1 x N x M [x F x G x ...]) where 
            % N and M are the receive and transmit aperture dimensions. 
            % 
            % See also CHANNELDATA/SAMPLE INTERP1 INTERPD INTERPF WSINTERPD CHANNELDATA/RECTIFYT0

            % defaults
            if nargin < 8, apdim = [chd.ndim, chd.mdim]; end
            if nargin < 7, fmod = 0; end
            if nargin < 6, sdim = [];           end
            if nargin < 5, w = 1;               end
            if nargin < 4, interp = 'linear';   end
            
            % move data up to match the sampling/apodization matrix
            D = max(3,ndims(chd.data));
            chd = swapdimD(chd, [chd.ndim, chd.mdim, 4:D], [apdim, max(apdim) + (1 : (D - 3))]);            

            % check condition that we can implicitly broadcast
            for tau = {tau1, tau2}
            for d = setdiff(1:gather(ndims(tau{1})), chd.tdim) % all dims except time must match
                assert(any(size(tau{1},d) == size(chd.data,d)) || ...
                     (1 == size(tau{1},d) || size(chd.data,d) == 1), ...
                    'Delay size must match the data size (%i) or be singleton in dimension %i.',...
                    size(chd.data, d), d ...
                    );
            end
            end

            % compute the integer delays, aiming for the smaller output
            D = max([ndims(chd.t0), ndims(tau1), ndims(tau2)]);
            if prod(max(size(tau1,1:D), size(chd.t0,1:D))) ...
             < prod(max(size(tau2,1:D), size(chd.t0,1:D)))
                ntau1 = (tau1 - chd.t0) .* chd.fs;
                ntau2 = (tau2) .* chd.fs;
            else
                ntau2 = (tau2 - chd.t0) .* chd.fs;
                ntau1 = (tau1) .* chd.fs;
            end

            % apply the modulation vector as weights
            omega = 2i*pi*fmod / chd.fs; % modulation phasor

            % dispatch
            if istall(ntau1) || istall(chd.data)
                y = matlab.tall.transform(@wsinterpd2, chd.data, ntau1, ntau2, chd.tdim, w, sdim, interp, 0, omega);
            else
                y = wsinterpd2(chd.data, ntau1, ntau2, chd.tdim, w, sdim, interp, 0, omega);
            end
        end
        
        function chd = alignInt(chd, interp)
            % ALIGNINT - Align data to integer sampling
            %
            % chd = ALIGNINT(chd, interp) returns a ChannelData object
            % resampled to have an integer time axis. 
            % 
            % This can be used to compress the data to an integer type, but
            % may erase information about the true sampling frequency and
            % initial time which is used by beamforming algorithms. It can 
            % be useful if you want to store many ChannelData objects with 
            % less precision and only cast them to a floating-point type 
            % when they are being processed.
            % 
            % See also CHANNELDATA/RECTIFYT0 CHANNELDATA/SAMPLE 

            if nargin < 2, interp = 'cubic'; end
            n0_ = floor(min(chd.t0, [], 'all') * chd.fs); % get minimum integer time
            chd = rectifyt0(chd, interp, n0_  / chd.fs); % set data on the same time axis
            [chd.t0, chd.fs] = deal(n0_, 1);
        end    
        function f = fftaxis(chd)
            f = cast(shiftdim((0 : chd.T - 1)', 1-chd.tdim) .* chd.fs ./ chd.T, 'like', real(chd.data));
        end
    end

    % plotting and display
    methods
        function h = imagesc(chd, m, varargin, im_args)
            % IMAGESC - Overload of imagesc function
            %
            % h = IMAGESC(chd, m) displays transmit m of the channel data 
            % and returns the handle h.
            %
            % h = IMAGESC(chd, m, ax) uses the axes ax instead of the axes
            % returned by gca. 
            %
            % h = IMAGESC(..., 'YData', yax) uses the yax for the
            % y-axis instead of the time domain.
            % 
            % h = IMAGESC(..., Name, Value, ...) passes the following
            % arguments to the imagesc function.
            %
            % Example:
            % % Create some data
            % chd = ChannelData('data', rand([256, 32, 5]));  
            % 
            % % Show the data
            % figure;
            % imagesc(chd); % shows the middle transmit
            %
            % % Show the data in the frequency domain in MHz
            % f = chd.fs*(0:chd.T-1)/chd.T; % frequency axis
            % figure; 
            % imagesc(fft(chd), 1, 'YData', 1e-6*f);
            %
            % See also IMAGESC
            arguments
                chd ChannelData
                m {mustBeInteger} = ceil(chd.M/2); 
            end
            arguments(Repeating)
                varargin
            end
            arguments
                im_args.?matlab.graphics.primitive.Image
            end

            % find axis varargs
            if numel(varargin) >= 1 && isa(varargin{1}, 'matlab.graphics.axis.Axes')
                ax = varargin{1}; varargin(1) = [];
            else
                ax = gca;
            end

            % get full data sizing
            dims = gather(max(3, [ndims(chd.data)])); % (minimum) number of dimensions
            idims = [chd.tdim, chd.ndim]; % image dimensions
            fdims = setdiff(1:dims, idims); % frame dimensions
            dsz = gather(size(chd.data, fdims)); % full size - data dimensions
            tsz = gather(size(chd.time, fdims));

            % we index the data linearly, but the time axes may be
            % implicitly broadcasted: we can use ind2sub to recover it's
            % sizing
            ix = cell([numel(fdims), 1]); % indices of the frame for the data
            [ix{:}] = ind2sub(dsz, gather(m)); % get cell array of indices
            it = gather(min([ix{:}], tsz)); % restrict to size of chd.time
            ix = cellfun(@gather, ix, 'UniformOutput', false); % enforce on CPU

            % select the transmit/frame - we can only show first 2
            % dimensions, time x rx
            d = gather(sub(chd.data, ix, fdims));
            d = permute(d, [idims, fdims]); % move image dimensions down 

            % choose to show real part or dB magnitude
            if isnumeric(d), d = double(d); end % cast integer types for abs, half types for imagesc
            d = squeeze(double(d)); % make friendly to imagesc
            if ~isreal(d), d = mod2db(d); end % assume complex data should be shown in dB

            % get the time axes for this frame
            t = gather(double(sub(chd.time, num2cell(it), fdims)));

            % choose which dimensions to show
            if ~isfield(im_args, 'XData'), im_args.XData = 1:chd.N; end
            if ~isfield(im_args, 'YData'), im_args.YData = t; end 

            % show the data
            im_args = struct2nvpair(im_args);
            h = imagesc(ax, d, varargin{:}, im_args{:});
        end

        function gif(chd, filename, h, varargin)
            % GIF - Write the ChannelData to a GIF file
            %
            % GIF(chd, filename) writes the ChannelData chd to the file
            % filename.
            %
            % GIF(chd, filename, h) updates the image handle h rather than
            % creating a new image. Use imagesc to create an image handle.
            % You can then format the figure prior to calling this
            % function.
            %
            % GIF(..., Name, Value, ...) forwards Name/Value pairs to
            % imwrite. 
            %
            % Example:
            % sz = [2^8, 2^6, 2^6];
            % x = complex(rand(sz), rand(sz)) - (0.5 + 0.5i);
            % chd = angle(ChannelData('data', x));
            % figure;
            % h = imagesc(chd, 1);
            % colormap hsv; 
            % colorbar;
            % gif(chd, 'random_phase.gif', h, 'DelayTime', 1/20);
            %
            % See also IMAGESC ANIMATE

            % defaults
            kwargs = struct('LoopCount', Inf, 'DelayTime', 1/15);

            % parse inputs
            for i = 1:2:numel(varargin), kwargs.(varargin{1}) = varargin{i+1}; end

            % if no image handle, create a new image
            if nargin < 3, h = imagesc(chd, 1); end
            
            chd = rectifyDims(chd); % put in proper order
            x = chd.data; % all data
            M_ = prod(size(x, 3:min(3,ndims(x)))); % all slices

            % get image frames
            % TODO: there's some weird bug where the size is randomly off 
            % by 10 pixels here? Can I work around it?
            for m = M_:-1:1, h.CData(:) = x(:,:,m); fr{m} = getframe(h.Parent.Parent); end
            
            % get color space for the image
            [~, map] = rgb2ind(fr{1}.cdata, 256, 'nodither');

            % get all image data
            im = cellfun(@(fr) {rgb2ind(fr.cdata,map,'nodither')}, fr);
            im = cat(4, im{:});

            % forward to imwrite
            nvkwargs = struct2nvpair(kwargs);
            imwrite(im, map, filename, nvkwargs{:});
        end
    end

    % dependent methods
    methods
        function set.time(chd, t)
            % set.time - set the time axis
            %
            % time must be of dimensions (T x 1 x [1|M]) where M is the
            % number of transmits.

            % TODO: validate size
            % TODO: warn or error if time axis is not regularly spaced

            %  get the possible sampling freuqencies
            fs_ = unique(diff(t,1,chd.tdim));

            % choose the sampling frequency with the best adherence to the
            % data
            t0_ = sub(t, 1, chd.tdim);
            m = arrayfun(@(fs) sum(abs((t0_ + swapdim((0 : numel(t) - 1),2,chd.tdim) ./ fs ) - t), 'all'), fs_);
            fs_ = fs_(argmin(m,[],'all'));

            % set the time axis
            chd.t0 = t0_;
            chd.fs = fs_;
        end
        function t = get.time(chd), t = cast(chd.t0 + shiftdim((0 : chd.T - 1)', 1-chd.tdim) ./ chd.fs, 'like', real(chd.data)); end % match data type, except always real
        function T = get.T(chd), T = gather(size(chd.data,chd.tdim)); end
        function N = get.N(chd), N = gather(size(chd.data,chd.ndim)); end
        function M = get.M(chd), M = gather(size(chd.data,chd.mdim)); end
    end

    % sizing functions (used to control tall behaviour and reshaping)
    properties(Hidden, Dependent)
        tdim % time dimension
        ndim % receiver dimension
        mdim % transmitter dimension
    end

    % data indexing functions
    methods
        function chd = join(chds, dim)
            % JOIN - Merge an array of ChannelData objects
            %
            % chd = JOIN(chds, dim) merges the ChannelData array chds into
            % a single ChannelData objects chd in dimension dim of the
            % data. 
            % 
            % The temporal dimension is expanded as needed. All other
            % dimensions must be an identical size or empty. The sampling 
            % frequency must be identical.
            %
            % The start time t0 must be either full in dimension dim or 
            % identical in dimension dim for all ChannelData objects.
            %
            % See also CHANNELDATA/SPLICE
            
            if isempty(chds), sz=size(chds); sz(dim)=1; chd=reshape(chds, sz); return; end % trivial case
            assert(isalmostn([chds.fs], repmat(median([chds.fs]), [1,numel(chds)]))); % sampling frequency must be identical
            assert(all(string(chds(1).order) == {chds.order})); % data orders are identical

            T_ = max([chds.T]); % maximum length of data
            chds = arrayfun(@(chds) zeropad(chds,0,T_ - chds.T), chds); % make all the same length
            chd = ChannelData('t0', cat(dim,chds.t0), 'fs', median([chds.fs]), 'data', cat(dim, chds.data), 'order', chds(1).order); % combine
            if all(chd.t0 == sub(chd.t0,1,dim),'all'), chd.t0 = sub(chd.t0,1,dim); end % simplify for identical t0

        end
        function [chds, ix] = splice(chd, dim, bsize)
            % SPLICE - Split the ChannelData into an array of ChannelDatas
            % 
            % chds = SPLICE(chd, dim) returns an array of ChannelData
            % objects chds where each element contains a slice of the data
            % in dimensions dim. It is useful for iterating over
            % ChannelData without explicitly indexing the data and time
            % dimensions manually.
            %
            % chds = SPLICE(chd, dim, bsize) uses a maximum block size of 
            % bsize to partition the ChannelData objects. The default is 1.
            %
            % [chds, ix] = SPLICE(...) also returns the indices for each 
            % ChannelData in the spliced dimension. For example, if chd is
            % spliced with a block size of 2 over a dimension of length 5,
            % ix = {[1 2], [3 4], [5]}.
            %
            % Example:
            % 
            % % Create data
            % [T, N, M] = deal(2^10, 8, 8);
            % t = (0 : T - 1)'; % time axis
            % f = shiftdim((M/2 : 0.5 : M - 1/2) / M / 2, -1); % frequencies per transmit (normalized)
            % x = sinpi(2 .* f .* t); % sinusoids
            % w = randn([T, N, M]); % white noise
            % chd = ChannelData('data', x + w, 't0', t(1), 'fs', 1);
            % 
            % % Estimate the central frequency for each transmit
            % chds = splice(chd, chd.mdim); % splice per transmit
            % for m = 1:chd.M, fc(m) = estfc(chds(m)); end % estimate per transmit
            % figure; plot(1:chd.M, [f(:), fc(:)], '.-'); 
            % title('Estimated frequency per transmit');
            % legend({'True', 'Estimated'});
            % 
            % See also CHANNELDATA/JOIN SUB
            
            assert(isscalar(dim), 'Dimension must be scalar!'); 
            if nargin < 3, bsize = 1; end

            % S = gather(size(chd.data, dim)); % slices
            St = gather(size(chd.t0  ,dim)); % size in t
            Sx = gather(size(chd.data,dim)); % size in x
            it = num2cell((0:bsize:St-1) + (1:bsize)',1); % index up to maximum t
            ix = num2cell((0:bsize:Sx-1) + (1:bsize)',1); % index up to maximum x
            it{end}(it{end} > St) = []; % restrict to actual max t
            ix{end}(ix{end} > Sx) = []; % restrict to actual max x

            % splice data and time axes
            t = cellfun(@(i) sub(chd.t0  , i, dim), it, 'UniformOutput',false);
            x = cellfun(@(i) sub(chd.data, i, dim), ix, 'UniformOutput',false);
            
            % make array of new ChannelData objects
            chds = repmat(ChannelData('fs', chd.fs, 'order', chd.order), [max(numel(t),numel(x)),1]); % new ChannelData objects
            chds = arrayfun(@copy, shiftdim(chds, 1-dim)); % make unique and move to dimension dim
            [chds.t0  ] = deal(t{:}); % set start time(s)
            [chds.data] = deal(x{:}); % set data

        end
        function chd = subD(chd, ind, dim)
            if ~iscell(ind), ind = {ind}; end % enforce cell syntax
            tind = ind; % separate copy for the time indices
            tind(size(chd.time,dim) == 1) = {1}; % set singleton where t0 is sliced
            has_tdim = any(dim == chd.tdim); % whether we are idnexing in the time dimension too
            if has_tdim 
                n = tind{dim == chd.tdim}; % get the time indices
                if isnumeric(n)
                    assert(issorted(n, 'strictascend') && all(n == round(n)), ... % check the index in time is sorted, continous
                        'The temporal index must be a strictly increasing set of indices.');
                elseif islogical(n)
                    n = find(n);
                    assert(issorted(n, 'strictascend') && all(n == round(n)), ... % check the index in time is sorted, continous
                        'The temporal index must be a strictly increasing set of indices.');
                else % not sure, but allow ...
                end
            end
            t0_   = sub(chd.t0, tind(dim ~= chd.tdim), dim(dim ~= chd.tdim)); % extract start time
            data_ = sub(chd.data, ind, dim); % extract data
            % get the new start time based on the starting index
            % should preserve type and size fo t0
            if has_tdim && ~isempty(n), t0_(:) = t0_ + (n(1) - 1) / chd.fs; end 
            
            chd = copy(chd); % copy semantics
            chd.t0 = t0_; % assign
            chd.data = data_; % assign

        end
        function chd = setOrder(chd, cord)
            assert(...
                length(cord) >= ndims(chd.data),...
                'Number of dimension labels must be greater than or equal to the number of data dimensions.'...
                ); 
            assert(...
                all(ismember('TMN', cord)), ...
                "Dimension labels must contain 'T', 'N', and 'M'."...
                );
            chd.order = cord; 
        end
        function chd = expandDims(chd, d)
            chd = copy(chd); % copy semantics
            for j = 1:numel(chd)
                nc = numel(chd(j).order); % number of dimension labels
                ccand = setdiff(char(double('F') + (0 : 2*(d-nc))), chd(j).order); % get unique labels, starting with 'F'
                chd(j).order(nc+1:d) = ccand(1:d-nc);
            end
        end
        function chd = swapdimD(chd, i, o)
            D = max([i,o,ndims(chd), cellfun(@numel, {chd.order}), cellfun(@ndims, {chd.data})]); % max possible dim
            ord = 1:D;
            l = min(min(i),min(o)) : max(max(i),max(o)); % all indices within swap
            i = [i, setdiff(l, i)]; % expanded input indices
            o = [o, setdiff(l, o)]; % expanded output indices
            ord(o) = i; % full permutation ordering
            for j = 1:numel(chd)
                chd(j) = expandDims(chd(j), D); % expand to have enough dim labels
                chd(j).data = swapdim(chd(j).data, i, o); % swap data
                chd(j).t0   = swapdim(chd(j).t0  , i, o); % swap start time
                chd(j).order  = chd(j).order(ord); % swap labels
            end
        end
        function chd = permuteD(chd, dord)
            chd = expandDims(chd, max(dord)); % expand to have enough dim labels
            for j = 1:numel(chd)
                chd(j).data = permute(chd(j).data, dord); % change data dimensions
                chd(j).t0   = permute(chd(j).t0, dord); % change t0 dimensions
                chd(j).order(1:numel(dord)) = chd(j).order(dord); % change data order
            end
        end
        function chd = ipermuteD(chd, dord)
            chd = expandDims(chd, max(dord)); % expand to have enough dim labels
            for j = 1:numel(chd)
                chd(j).data = ipermute(chd(j).data, dord); % change data dimensions
                chd(j).t0   = ipermute(chd(j).t0, dord); % change t0 dimensions
                chd(j).order(1:numel(dord)) = chd(j).order(dord); % change data order
            end
        end
        function [chd, dord] = rectifyDims(chd)
            % RECTIFYDIMS - Set dimensions to default order
            %
            % chd = RECTIFYDIMS(chd) sets the dimension of the data to
            % their default order of time x receive x transmit x ...
            %
            for j = 1:numel(chd)
                chdj = chd(j);
                D = gather(max(numel(chdj.order), ndims(chdj.data))); % number of dimensions
                [~, dord] = ismember('TNM', chdj.order); % want this order to start
                dord = [dord, setdiff(1:D, dord)]; %#ok<AGROW> % make sure we have all dimensions accounted for
                chd(j) = permuteD(chdj, dord); % set dims to match in lower dimensions
                % chd = truncateDims(chd); % remove unnecessary dimensions
            end
        end
        function chd = truncateDims(chd)
            nd = numel(chd.order); % number of (labelled) dimensions
            [~,o] = ismember('TMN', chd.order); % position of necessary params
            sdims = find(size(chd.data,1:nd) ~= 1); % singleton dims
            kdims = sort(union(o, sdims)); % dims to keep: necessary or non-singleton
            rdims = setdiff(1:nd, kdims); % dims to remove: all others
            chd = permuteD(chd, [kdims, rdims]); % squeeze data down
            chd.order = chd.order(kdims); % remove unnecesary dimensions 
        end
    end
    methods
        function d = get.tdim(chd), d = find(chd.order == 'T'); end
        function d = get.ndim(chd), d = find(chd.order == 'N'); end
        function d = get.mdim(chd), d = find(chd.order == 'M'); end
    end
    
    % aliases
    properties(Hidden, Dependent)
        ord
    end
    methods % deprecated
        function o = get.ord(chd), warning("QUPS:ChannelData:syntaxDeprecated","ChannelData.ord is deprecated. Use the .order property instead."); o = chd.order; end
        function set.ord(chd, o),  warning("QUPS:ChannelData:syntaxDeprecated","ChannelData.ord is deprecated. Use the .order property instead."); chd.order = o; end
    end
end

% TODO: make a default interpolation method property